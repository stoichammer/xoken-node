{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MonoLocalBinds #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE BangPatterns #-}

module Network.Xoken.Node.Service.Transaction where

import Arivi.P2P.MessageHandler.HandlerTypes (HasNetworkConfig, networkConfig)
import Arivi.P2P.P2PEnv
import Arivi.P2P.PubSub.Class
import Arivi.P2P.PubSub.Env
import Arivi.P2P.PubSub.Publish as Pub
import Arivi.P2P.PubSub.Types
import Arivi.P2P.RPC.Env
import Arivi.P2P.RPC.Fetch
import Arivi.P2P.Types hiding (msgType)
import Codec.Serialise
import Conduit hiding (runResourceT)
import Control.Applicative
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (AsyncCancelled, mapConcurrently, mapConcurrently_, race_)
import qualified Control.Concurrent.Async.Lifted as LA (async, concurrently, mapConcurrently, wait)
import Control.Concurrent.MVar
import Control.Concurrent.STM
import Control.Concurrent.STM.TVar
import qualified Control.Error.Util as Extra
import Control.Exception
import Control.Exception
import qualified Control.Exception.Lifted as LE (try)
import Control.Monad
import Control.Monad.Extra
import Control.Monad.IO.Class
import Control.Monad.Logger
import Control.Monad.Loops
import Control.Monad.Reader
import Control.Monad.Trans.Control
import Data.Aeson as A
import qualified Data.ByteString as B
import qualified Data.ByteString.Base16 as B16 (decode, encode)
import Data.ByteString.Base64 as B64
import Data.ByteString.Base64.Lazy as B64L
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy as BSL
import qualified Data.ByteString.Lazy.Char8 as C
import qualified Data.ByteString.Short as BSS
import qualified Data.ByteString.UTF8 as BSU (toString)
import Data.Char
import Data.Default
import qualified Data.HashTable.IO as H
import Data.Hashable
import Data.IORef
import Data.Int
import Data.List
import qualified Data.List as L
import Data.Map.Strict as M
import Data.Maybe
import Data.Pool
import qualified Data.Serialize as S
import Data.Serialize
import qualified Data.Serialize as DS (decode, encode)
import qualified Data.Set as S
import Data.String (IsString, fromString)
import qualified Data.Text as DT
import qualified Data.Text.Encoding as DTE
import qualified Data.Text.Encoding as E
import Data.Time.Calendar
import Data.Time.Clock
import Data.Time.Clock.POSIX
import Data.Word
import Data.Yaml
import qualified Database.Bolt as BT
import Database.XCQL.Protocol as Q
import qualified Network.Simple.TCP.TLS as TLS
import Network.Xoken.Address.Base58
import Network.Xoken.Block.Common
import Network.Xoken.Crypto.Hash
import Network.Xoken.Node.Data
import Network.Xoken.Node.Data.Allegory
import Network.Xoken.Node.Env
import Network.Xoken.Node.GraphDB
import Network.Xoken.Node.P2P.BlockSync
import Network.Xoken.Node.P2P.Common
import Network.Xoken.Node.P2P.Types
import Network.Xoken.Util (bsToInteger, integerToBS)
import Numeric (showHex)
import System.Logger as LG
import System.Logger.Message
import System.Random
import Text.Read
import Xoken
import qualified Xoken.NodeConfig as NC

xGetTxHash :: (HasXokenNodeEnv env m, MonadIO m) => DT.Text -> m (Maybe RawTxRecord)
xGetTxHash hash = do
    dbe <- getDB
    lg <- getLogger
    bp2pEnv <- getBitcoinP2P
    ep <- liftIO $ readTVarIO (epochType bp2pEnv)
    let conn = xCqlClientState dbe
        net = NC.bitcoinNetwork $ nodeConfig bp2pEnv
        str = "SELECT tx_id, block_info, tx_serialized, inputs, fees from xoken.transactions where tx_id = ?"
        qstr =
            str :: Q.QueryString Q.R (Identity DT.Text) ( DT.Text
                                                        , (DT.Text, Int32, Int32)
                                                        , Blob
                                                        , Set ((DT.Text, Int32), Int32, (DT.Text, Int64))
                                                        , Int64)
        ustr =
            "SELECT epoch, tx_id, tx_serialized, inputs, fees from xoken.ep_transactions where epoch = ? AND tx_id = ?"
        uqstr =
            ustr :: Q.QueryString Q.R (Bool, DT.Text) ( Bool
                                                      , DT.Text
                                                      , Blob
                                                      , Set ((DT.Text, Int32), Int32, (DT.Text, Int64))
                                                      , Int64)
        p = getSimpleQueryParam $ Identity $ hash
        up = getSimpleQueryParam $ (ep, hash)
    res <-
        LE.try $
        LA.concurrently
            (LA.concurrently (liftIO $ query conn (Q.RqQuery $ Q.Query qstr p)) (getTxOutputsFromTxId hash))
            (xGetMerkleBranch $ DT.unpack hash)
    case res of
        Right ((iop, outs), mrkl) ->
            if length iop == 0
                then do
                    ures <- LE.try $ liftIO $ query conn (Q.RqQuery $ Q.Query uqstr up)
                    case ures of
                        Right uiop ->
                            if length uiop == 0
                                then return Nothing
                                else do
                                    let (epoch, txid, psz, sinps, fees) = uiop !! 0
                                        inps = L.sortBy (\(_, x, _) (_, y, _) -> compare x y) $ Q.fromSet sinps
                                    sz <-
                                        if isSegmented $ fromBlob psz
                                            then liftIO $ getCompleteUnConfTx conn hash (getSegmentCount (fromBlob psz))
                                            else pure $ fromBlob psz
                                    let tx = fromJust $ Extra.hush $ S.decodeLazy sz
                                    return $
                                        Just $
                                        RawTxRecord
                                            (DT.unpack txid)
                                            (fromIntegral $ C.length sz)
                                            Nothing
                                            (sz)
                                            (Just $ zipWith mergeTxOutTxOutput (txOut tx) outs)
                                            (zipWith mergeTxInTxInput (txIn tx) $
                                             (\((outTxId, outTxIndex), inpTxIndex, (addr, value)) ->
                                                  TxInput
                                                      (DT.unpack outTxId)
                                                      outTxIndex
                                                      inpTxIndex
                                                      (DT.unpack addr)
                                                      value
                                                      "") <$>
                                             inps)
                                            fees
                                            Nothing
                        Left (e :: SomeException) -> do
                            err lg $ LG.msg $ "Error: xGetTxHash: " ++ show e
                            throw KeyValueDBLookupException
                else do
                    let (txid, (bhash, blkht, txind), psz, sinps, fees) = iop !! 0
                        inps = L.sortBy (\(_, x, _) (_, y, _) -> compare x y) $ Q.fromSet sinps
                    sz <-
                        if isSegmented $ fromBlob psz
                            then liftIO $ getCompleteTx conn hash (getSegmentCount (fromBlob psz))
                            else pure $ fromBlob psz
                    let tx = fromJust $ Extra.hush $ S.decodeLazy sz
                    return $
                        Just $
                        RawTxRecord
                            (DT.unpack txid)
                            (fromIntegral $ C.length sz)
                            (Just $ BlockInfo' (DT.unpack bhash) (fromIntegral blkht) (fromIntegral txind))
                            (sz)
                            (Just $ zipWith mergeTxOutTxOutput (txOut tx) outs)
                            (zipWith mergeTxInTxInput (txIn tx) $
                             (\((outTxId, outTxIndex), inpTxIndex, (addr, value)) ->
                                  TxInput (DT.unpack outTxId) outTxIndex inpTxIndex (DT.unpack addr) value "") <$>
                             inps)
                            fees
                            (Just mrkl)
        Left (e :: SomeException) -> do
            err lg $ LG.msg $ "Error: xGetTxHash: " ++ show e
            throw KeyValueDBLookupException

xGetTxHashes :: (HasXokenNodeEnv env m, MonadIO m) => [DT.Text] -> m ([RawTxRecord])
xGetTxHashes hashes = do
    dbe <- getDB
    lg <- getLogger
    bp2pEnv <- getBitcoinP2P
    ep <- liftIO $ readTVarIO (epochType bp2pEnv)
    let conn = xCqlClientState dbe
        net = NC.bitcoinNetwork $ nodeConfig bp2pEnv
        str = "SELECT tx_id, block_info, tx_serialized, inputs, fees from xoken.transactions where tx_id in ?"
        ustr = "SELECT tx_id, tx_serialized, inputs, fees from xoken.ep_transactions where epoch = ? AND tx_id = ?"
        qstr =
            str :: Q.QueryString Q.R (Identity [DT.Text]) ( DT.Text
                                                          , (DT.Text, Int32, Int32)
                                                          , Blob
                                                          , Set ((DT.Text, Int32), Int32, (DT.Text, Int64))
                                                          , Int64)
        uqstr =
            ustr :: Q.QueryString Q.R (Bool, DT.Text) ( DT.Text
                                                      , Blob
                                                      , Set ((DT.Text, Int32), Int32, (DT.Text, Int64))
                                                      , Int64)
        p = getSimpleQueryParam $ Identity $ hashes
        up a = getSimpleQueryParam $ (ep, a)
    res <- liftIO $ LE.try $ query conn (Q.RqQuery $ Q.Query qstr p)
    ures <- liftIO $ LE.try $ mapConcurrently (\a -> query conn (Q.RqQuery $ Q.Query uqstr (up a))) hashes
    cres <-
        case res of
            Right iop ->
                pure $
                L.map
                    (\(txid, (bhash, blkht, txind), psz, sinps, fees) ->
                         (txid, Just (bhash, blkht, txind), psz, Q.fromSet sinps, fees))
                    iop
            Left (e :: SomeException) -> do
                err lg $ LG.msg $ "Error: xGetTxHashes: " ++ show e
                throw KeyValueDBLookupException
    cures <-
        case ures of
            Right iop -> do
                pure $ L.map (\(txid, psz, sinps, fees) -> (txid, Nothing, psz, Q.fromSet sinps, fees)) (L.concat iop)
            Left (e :: SomeException) -> do
                err lg $ LG.msg $ "Error: xGetTxHashes: " ++ show e
                throw KeyValueDBLookupException
    let iop = nubBy (\(txid, _, _, _, _) (txid2, _, _, _, _) -> txid == txid2) (cres ++ cures)
    txRecs <-
        traverse
            (\(txid, bi, psz, sinps, fees) -> do
                 let inps = L.sortBy (\(_, x, _) (_, y, _) -> compare x y) sinps
                 sz <-
                     if isSegmented (fromBlob psz)
                         then liftIO $ getCompleteTx conn txid (getSegmentCount (fromBlob psz))
                         else pure $ fromBlob psz
                 let tx = fromJust $ Extra.hush $ S.decodeLazy sz
                 let mrklF =
                         case bi of
                             Just b -> Just <$> (xGetMerkleBranch $ DT.unpack txid)
                             Nothing -> pure Nothing
                 let oF = Just <$> getTxOutputsFromTxId txid
                 res' <- LE.try $ LA.concurrently oF mrklF
                 case res' of
                     Right (outs, mrkl) ->
                         return $
                         Just $
                         RawTxRecord
                             (DT.unpack txid)
                             (fromIntegral $ C.length sz)
                             ((\(bhash, blkht, txind) ->
                                   BlockInfo' (DT.unpack bhash) (fromIntegral blkht) (fromIntegral txind)) <$>
                              bi)
                             (sz)
                             (zipWith mergeTxOutTxOutput (txOut tx) <$> outs)
                             (zipWith mergeTxInTxInput (txIn tx) $
                              (\((outTxId, outTxIndex), inpTxIndex, (addr, value)) ->
                                   TxInput (DT.unpack outTxId) outTxIndex inpTxIndex (DT.unpack addr) value "") <$>
                              inps)
                             fees
                             mrkl
                     Left (e :: SomeException) -> do
                         err lg $ LG.msg $ "Error: xGetTxHashes: " ++ show e
                         return Nothing)
            iop
    return $ fromMaybe [] (sequence txRecs)

getTxOutputsFromTxId :: (HasXokenNodeEnv env m, HasLogger m, MonadIO m) => DT.Text -> m [TxOutput]
getTxOutputsFromTxId txid = do
    dbe <- getDB
    lg <- getLogger
    bp2pEnv <- getBitcoinP2P
    ep <- liftIO $ readTVarIO (epochType bp2pEnv)
    let conn = xCqlClientState dbe
        toStr = "SELECT output_index,block_info,is_recv,other,value,address FROM xoken.txid_outputs WHERE txid=?"
        toQStr =
            toStr :: Q.QueryString Q.R (Identity DT.Text) ( Int32
                                                          , (DT.Text, Int32, Int32)
                                                          , Bool
                                                          , Set ((DT.Text, Int32), Int32, (DT.Text, Int64))
                                                          , Int64
                                                          , DT.Text)
        par = getSimpleQueryParam (Identity txid)
        utoStr = "SELECT output_index,is_recv,other,value,address FROM xoken.ep_txid_outputs WHERE epoch = ? AND txid=?"
        utoQStr =
            utoStr :: Q.QueryString Q.R ((Bool, DT.Text)) ( Int32
                                                          , Bool
                                                          , Set ((DT.Text, Int32), Int32, (DT.Text, Int64))
                                                          , Int64
                                                          , DT.Text)
        upar = getSimpleQueryParam (ep, txid)
    ures <- liftIO $ LE.try $ query conn (Q.RqQuery $ Q.Query utoQStr upar)
    res <- liftIO $ LE.try $ query conn (Q.RqQuery $ Q.Query toQStr par)
    uout <-
        case ures of
            Right ut -> do
                if L.null ut
                    then do
                        err lg $
                            LG.msg $ "Error: getTxOutputsFromTxId: No entry in ep_txid_outputs for txid: " ++ show txid
                        return []
                    else do
                        let txg =
                                (L.sortBy (\(_, x, _, _, _) (_, y, _, _, _) -> compare x y)) <$>
                                (L.groupBy (\(x, _, _, _, _) (y, _, _, _, _) -> x == y) ut)
                            txOutData =
                                (\inp ->
                                     case inp of
                                         [(idx, recv, oth, val, addr)] ->
                                             genUnConfTxOutputData (txid, idx, (recv, oth, val, addr), Nothing)
                                         [(idx1, recv1, oth1, val1, addr1), (_, recv2, oth2, val2, addr2)] ->
                                             genUnConfTxOutputData
                                                 ( txid
                                                 , idx1
                                                 , (recv2, oth2, val2, addr2)
                                                 , Just (recv1, oth1, val1, addr1))) <$>
                                txg
                        return $ txOutputDataToOutput <$> txOutData
            Left (e :: SomeException) -> do
                err lg $ LG.msg $ "Error: getTxOutputsFromTxId: " ++ show e
                throw KeyValueDBLookupException
    out <-
        case res of
            Right t -> do
                if length t == 0
                    then do
                        err lg $
                            LG.msg $ "Error: getTxOutputsFromTxId: No entry in txid_outputs for txid: " ++ show txid
                        return []
                    else do
                        let txg =
                                (L.sortBy (\(_, _, x, _, _, _) (_, _, y, _, _, _) -> compare x y)) <$>
                                (L.groupBy (\(x, _, _, _, _, _) (y, _, _, _, _, _) -> x == y) t)
                            txOutData =
                                (\inp ->
                                     case inp of
                                         [(idx, bif, recv, oth, val, addr)] ->
                                             genTxOutputData (txid, idx, (bif, recv, oth, val, addr), Nothing)
                                         [(idx1, bif1, recv1, oth1, val1, addr1), (_, bif2, recv2, oth2, val2, addr2)] ->
                                             genTxOutputData
                                                 ( txid
                                                 , idx1
                                                 , (bif2, recv2, oth2, val2, addr2)
                                                 , Just (bif1, recv1, oth1, val1, addr1))) <$>
                                txg
                        return $ txOutputDataToOutput <$> txOutData
            Left (e :: SomeException) -> do
                err lg $ LG.msg $ "Error: getTxOutputsFromTxId: " ++ show e
                throw KeyValueDBLookupException
    return $ uout ++ out

xGetTxIDsByBlockHash :: (HasXokenNodeEnv env m, HasLogger m, MonadIO m) => String -> Int32 -> Int32 -> m [String]
xGetTxIDsByBlockHash hash pgSize pgNum = do
    dbe <- getDB
    lg <- getLogger
    let conn = xCqlClientState $ dbe
        txsToSkip = pgSize * (pgNum - 1)
        firstPage = (+ 1) $ fromIntegral $ floor $ (fromIntegral txsToSkip) / 100
        lastPage = (+ 1) $ fromIntegral $ floor $ (fromIntegral $ txsToSkip + pgSize) / 100
        txDropFromFirst = fromIntegral $ txsToSkip `mod` 100
        str = "SELECT page_number, txids from xoken.blockhash_txids where block_hash = ? and page_number in ? "
        qstr = str :: Q.QueryString Q.R (DT.Text, [Int32]) (Int32, [DT.Text])
        p = getSimpleQueryParam $ (DT.pack hash, [firstPage .. lastPage])
    res <- liftIO $ try $ query conn (Q.RqQuery $ Q.Query qstr p)
    case res of
        Right iop ->
            return . L.take (fromIntegral pgSize) . L.drop txDropFromFirst . L.concat $ (fmap DT.unpack . snd) <$> iop
        Left (e :: SomeException) -> do
            err lg $ LG.msg $ "Error: xGetTxIDsByBlockHash: " <> show e
            throw KeyValueDBLookupException

xGetTxOutputSpendStatus :: (HasXokenNodeEnv env m, MonadIO m) => String -> Int32 -> m (Maybe TxOutputSpendStatus)
xGetTxOutputSpendStatus txId outputIndex = do
    dbe <- getDB
    let conn = xCqlClientState dbe
        str = "SELECT is_recv, block_info, other FROM xoken.txid_outputs WHERE txid=? AND output_index=?"
        qstr =
            str :: Q.QueryString Q.R (DT.Text, Int32) ( Bool
                                                      , (DT.Text, Int32, Int32)
                                                      , Set ((DT.Text, Int32), Int32, (DT.Text, Int64)))
        p = getSimpleQueryParam (DT.pack txId, outputIndex)
    iop <- liftIO $ query conn (Q.RqQuery $ Q.Query qstr p)
    if length iop == 0
        then return Nothing
        else do
            if L.length iop == 1
                then return $ Just $ TxOutputSpendStatus False Nothing Nothing Nothing
                else do
                    let siop = L.sortBy (\(x, _, _) (y, _, _) -> compare x y) iop
                        (_, (_, spendingTxBlkHeight, _), other) = siop !! 0
                        ((spendingTxID, _), spendingTxIndex, _) = head $ Q.fromSet other
                    return $
                        Just $
                        TxOutputSpendStatus
                            True
                            (Just $ DT.unpack spendingTxID)
                            (Just spendingTxBlkHeight)
                            (Just spendingTxIndex)

xGetMerkleBranch :: (HasXokenNodeEnv env m, MonadIO m) => String -> m ([MerkleBranchNode'])
xGetMerkleBranch txid = do
    dbe <- getDB
    lg <- getLogger
    res <- liftIO $ try $ withResource (pool $ graphDB dbe) (`BT.run` queryMerkleBranch (DT.pack txid))
    case res of
        Right mb -> do
            return $ Data.List.map (\x -> MerkleBranchNode' (DT.unpack $ _nodeValue x) (_isLeftNode x)) mb
        Left (e :: SomeException) -> do
            err lg $ LG.msg $ "Error: xGetMerkleBranch: " ++ show e
            throw KeyValueDBLookupException

xRelayMultipleTx :: (HasXokenNodeEnv env m, MonadIO m) => [BC.ByteString] -> m [Bool]
xRelayMultipleTx = f []
  where
    f r [] = return r
    f r (t:ts) = xRelayTx t >>= \r' -> f (r' : r) ts

xRelayTx :: (HasXokenNodeEnv env m, MonadIO m) => BC.ByteString -> m (Bool)
xRelayTx rawTx = do
    dbe <- getDB
    lg <- getLogger
    bp2pEnv <- getBitcoinP2P
    let conn = xCqlClientState dbe
        bheight = 100000
        bhash = hexToBlockHash "0000000000000000000000000000000000000000000000000000000000000000"
    debug lg $ LG.msg $ "relayTx bhash " ++ show bhash
    -- broadcast Tx
    case runGetState (getConfirmedTx) (rawTx) 0 of
        Left e -> do
            err lg $ LG.msg $ "error decoding rawTx :" ++ show e
            throw ConfirmedTxParseException
        Right res -> do
            debug lg $ LG.msg $ val $ "broadcasting tx"
            case fst res of
                Just tx -> do
                    let outpoints = L.map (\x -> prevOutput x) (txIn tx)
                    tr <-
                        mapM
                            (\x -> do
                                 let txid = txHashToHex $ outPointHash $ prevOutput x
                                     str =
                                         "SELECT tx_id, block_info, tx_serialized from xoken.transactions where tx_id = ?"
                                     qstr =
                                         str :: Q.QueryString Q.R (Identity DT.Text) ( DT.Text
                                                                                     , (DT.Text, Int32, Int32)
                                                                                     , Blob)
                                     p = getSimpleQueryParam $ Identity $ (txid)
                                 iop <- liftIO $ query conn (Q.RqQuery $ Q.Query qstr p)
                                 if length iop == 0
                                     then do
                                         debug lg $ LG.msg $ "not found" ++ show txid
                                         return Nothing
                                     else do
                                         let (txid, _, psz) = iop !! 0
                                         sz <-
                                             if isSegmented (fromBlob psz)
                                                 then liftIO $ getCompleteTx conn txid (getSegmentCount (fromBlob psz))
                                                 else pure $ fromBlob psz
                                         case runGetLazy (getConfirmedTx) sz of
                                             Left e -> do
                                                 debug lg $ LG.msg (encodeHex $ BSL.toStrict sz)
                                                 return Nothing
                                             Right (txd) -> do
                                                 case txd of
                                                     Nothing -> return Nothing
                                                     Just txn -> do
                                                         let cout =
                                                                 (txOut txn) !!
                                                                 fromIntegral (outPointIndex $ prevOutput x)
                                                         case (decodeOutputBS $ scriptOutput cout) of
                                                             Right (so) -> do
                                                                 return $ Just (so, outValue cout, prevOutput x)
                                                             Left (e) -> do
                                                                 err lg $ LG.msg $ "error decoding rawTx :" ++ show e
                                                                 return Nothing)
                            (txIn tx)
                    -- if verifyStdTx net tx $ catMaybes tr
                    --     then do
                    allPeers <- liftIO $ readTVarIO (bitcoinPeers bp2pEnv)
                    let !connPeers = L.filter (\x -> bpConnected (snd x)) (M.toList allPeers)
                    debug lg $ LG.msg $ val $ "transaction verified - broadcasting tx"
                    mapM_ (\(_, peer) -> do sendRequestMessages peer (MTx (fromJust $ fst res))) connPeers
                    eres <- LE.try $ handleIfAllegoryTx tx True -- MUST be False
                    case eres of
                        Right (flg) -> return True
                        Left (e :: SomeException) -> return False
                Nothing -> do
                    err lg $ LG.msg $ val $ "error decoding rawTx (2)"
                    return $ False

xGetTxIDByProtocol ::
       (HasXokenNodeEnv env m, MonadIO m)
    => DT.Text
    -> [DT.Text]
    -> Maybe Int32
    -> Maybe Int64
    -> m [ResultWithCursor DT.Text Int64]
xGetTxIDByProtocol prop1 props pgSize mbNomTxInd = do
    dbe <- getDB
    lg <- getLogger
    bp2pEnv <- getBitcoinP2P
    let conn = xCqlClientState dbe
        net = NC.bitcoinNetwork $ nodeConfig bp2pEnv
        nominalTxIndex =
            case mbNomTxInd of
                (Just n) -> n
                Nothing -> maxBound
        protocol = DT.intercalate "." $ prop1 : props
        str = "SELECT txid, nominal_tx_index FROM xoken.script_output_protocol WHERE proto_str=? AND nominal_tx_index<?"
        qstr = str :: Q.QueryString Q.R (DT.Text, Int64) (DT.Text, Int64)
        uqstr = getSimpleQueryParam $ (protocol, nominalTxIndex)
    eResp <- liftIO $ LE.try $ query conn (Q.RqQuery $ Q.Query qstr (uqstr {pageSize = maybe (Just 100) Just pgSize}))
    case eResp of
        Right mb -> return $ (\(x, y) -> ResultWithCursor x y) <$> mb
        Left (e :: SomeException) -> do
            err lg $ LG.msg $ "Error: xGetTxIDByProtocol: " ++ show e
            throw KeyValueDBLookupException
