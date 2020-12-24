{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Network.Xoken.Node.HTTP.QueryHandler where

import Control.Exception
import Control.Monad.IO.Class
import Data.Aeson
import qualified Data.ByteString.Lazy as BSL
import Data.Either
import Data.HashMap.Strict
import qualified Data.HashMap.Strict as Map
import Data.List (find)
import qualified Data.Map.Strict as MMap
import Data.Maybe
import Data.Pool
import Data.Text
import qualified Data.Text.Encoding as DTE
import Data.Time.Calendar
import Data.Time.Clock
import Data.Time.Clock.POSIX
import Data.Vector
import qualified Database.Bolt as BT
import GHC.Generics
import Network.Xoken.Node.Env
import Network.Xoken.Node.HTTP.Handler
import Network.Xoken.Node.HTTP.Types
import Network.Xoken.Node.P2P.BlockSync
import Network.Xoken.Node.P2P.Common (addNewUser, generateSessionKey, getSimpleQueryParam, query, write)
import Network.Xoken.Node.P2P.Types hiding (node)
import Network.Xoken.Node.Service
import Prelude
import Snap
import qualified Text.Read as TR

tshow :: Show a => a -> Text
tshow = Data.Text.pack . show

showValue :: Value -> Text
showValue (String t) = t
showValue (Number s) = tshow s
showValue (Bool b) = tshow b
showValue (Array v) = tshow $ showValue <$> Data.Vector.toList v
showValue Null = ""
showValue (Object o) = tshow o -- :TODO not correct, yet shouldn't be used

operators :: [Text]
operators = ["$or", "$and", "$gt", "$gte", "$lt", "$lte", "$in", "$nin", "$eq", "$neq"]

showOp :: Text -> Text
showOp "$or" = " OR "
showOp "$and" = " AND "
showOp "$gt" = " > "
showOp "$gte" = " >= "
showOp "$lt" = " < "
showOp "$lte" = " <= "
showOp "$in" = " IN "
showOp "$nin" = " NOT IN "
showOp "$eq" = " = "
showOp "$neq" = " <> "
showOp x = x

encodeQuery :: HashMap Text Value -> Maybe Value -> HashMap Text Value -> NodeRelation -> Text
encodeQuery req ret grouped nr =
    let m = getMatch nr <> " Where "
        withWhere = foldlWithKey' (\acc k v -> acc <> handleOp k v) m req
     in (fromMaybe withWhere $
         (\r ->
              let current =
                      case r of
                          (Array v) ->
                              intercalate
                                  " , "
                                  ((\(Object hm) ->
                                        foldlWithKey' (\acc k v -> acc <> handleReturn k v) (withWhere <> " RETURN ") hm) <$>
                                   (Data.Vector.toList v))
                          (Object hm) ->
                              foldlWithKey' (\acc k v -> acc <> handleReturn k v) (withWhere <> " RETURN ") hm
                  other = foldlWithKey' (\acc k v -> acc <> handleReturn k v) " , " grouped
               in current <>
                  if " , " == other
                      then ""
                      else other) <$>
         ret)

handleOp :: Text -> Value -> Text
handleOp op v =
    case op of
        "$or" ->
            case v of
                Array v ->
                    intercalate (showOp op) $
                    fmap
                        (\x ->
                             case x of
                                 Object y -> foldlWithKey' (\acc k v -> acc <> handleOp' k v (showOp op)) "" y)
                        (Data.Vector.toList v)
                _ -> undefined
        "$and" ->
            case v of
                (Object y) ->
                    foldlWithKey'
                        (\acc k v ->
                             acc <>
                             if acc == ""
                                 then handleOp' k v (showOp op)
                                 else showOp op <> " " <> handleOp' k v (showOp op))
                        ""
                        y
                _ -> undefined
        k ->
            let (t, va) = dec v
             in k <> showOp t <> showValue va

handleOp' :: Text -> Value -> Text -> Text
handleOp' k v op =
    case v of
        Object hm -> intercalate op $ (\(k', v') -> k <> showOp k' <> showValue v') <$> Map.toList hm
        _ -> ""

dec :: Value -> (Text, Value)
dec v =
    case v of
        Object hm ->
            if Prelude.length (keys hm) == 1
                then (Prelude.head $ keys hm, Prelude.head $ elems hm)
                else (tshow $ keys hm, String "dum")
        x -> (showValue x, String "dum")

handleReturn :: Text -> Value -> Text
handleReturn "relation" (Object hm) =
    foldrWithKey
        (\k v acc ->
             acc <>
             (if acc == ""
                  then " r."
                  else " , r.") <>
             showValue v <> "(" <> k <> ")")
        ""
        hm
handleReturn x (Object hm) =
    foldrWithKey
        (\k v acc ->
             acc <>
             (if acc == ""
                  then " "
                  else " , ") <>
             (if showValue v == ""
                  then k
                  else showValue v <> "(" <> k <> ")"))
        ""
        hm

getMatch :: NodeRelation -> Text
getMatch nr =
    let m = "Match "
        f = "(" <> (aliasNode (_from nr :: Node)) <> ": " <> (node $ _from nr) <> " )"
        t =
            case _to nr of
                Just x -> "(" <> (aliasNode (x :: Node)) <> ": " <> (node x) <> " )"
                Nothing -> ""
        v =
            case _via nr of
                Just x ->
                    "-[" <>
                    (aliasRel (x :: Relation)) <>
                    ":" <>
                    (relationship x) <>
                    "]-" <>
                    (if direction x == Just True
                         then ">"
                         else "")
                Nothing ->
                    if isJust (_to nr)
                        then ","
                        else ""
     in m <> f <> v <> t

getMap :: [Grouped] -> HashMap Text Value
getMap groupeds =
    Prelude.foldl
        (\acc g -> do
             case g of
                 Day -> Map.insert "b.timestamp" (String "") $ Map.insert "b.month" (String "") acc
                 Month -> acc
                 Hour ->
                     Map.insert "b.timestamp" (String "") .
                     Map.insert "b.month" (String "") . Map.insert "b.absoluteHour" (String "") $
                     acc
                 Year -> acc)
        Map.empty
        groupeds

formatResponse :: [BT.Record] -> [BT.Record]
formatResponse = fmap go
  where
    go mapR = do
        let yearF = MMap.alter (fmap (\(BT.I y) -> BT.I (1970 + y))) "b.year"
        let month m =
                let x = Prelude.rem m 12
                 in if x == 0
                        then 12
                        else x
        let years mon = 1970 + (div mon 12)
        let monF =
                MMap.alter
                    (fmap (\(BT.I mon) -> BT.T (pack $ show (month mon) <> "/" <> show (1970 + (div mon 12)))))
                    "b.month"
        let mon = MMap.lookup "b.month" mapR
        let dayF map' =
                case mon of
                    Just (BT.I m) ->
                        MMap.alter
                            (\(Just (BT.I x)) ->
                                 Just
                                     (BT.T
                                          (pack $
                                           show x <>
                                           "/" <>
                                           show
                                               (if month m == 0
                                                    then 12
                                                    else m) <>
                                           "/" <> show (years m))))
                            "b.day"
                            map'
                    Nothing -> map'
        yearF . monF . dayF $ mapR

handleResponse :: Grouped -> [BT.Record] -> [BT.Record]
handleResponse group = fmap go
  where
    go m =
        case group of
            Day ->
                case Data.List.find (isInfixOf "day") (MMap.keys m) of
                    Just k -> do
                        let (Just (BT.I mon)) = MMap.lookup "b.month" m
                        let (Just (BT.I ts)) = MMap.lookup "b.timestamp" m
                        let years = 1970 + (div mon 12)
                        let month = Prelude.rem mon 12
                        let epd = utctDay $ posixSecondsToUTCTime 0
                        let cd = utctDay $ posixSecondsToUTCTime (fromIntegral ts)
                        let (_, d) = diffGregorianDurationClip cd epd
                        MMap.alter (const Nothing) "b.month" $
                            MMap.alter
                                (\(Just (BT.I x)) ->
                                     Just
                                         (BT.T
                                              (pack $
                                               show (d + 1) <>
                                               "/" <>
                                               show
                                                   (if month == 0
                                                        then 12
                                                        else month) <>
                                               "/" <> show years)))
                                k
                                m
                    Nothing -> m
            Month ->
                case Data.List.find (isInfixOf "month") (MMap.keys m) of
                    Just k -> do
                        let month m =
                                let x = Prelude.rem m 12
                                 in if x == 0
                                        then 12
                                        else x
                        MMap.alter
                            (\(Just (BT.I mon)) ->
                                 Just (BT.T (pack $ show (month mon) <> "/" <> show (1970 + (div mon 12)))))
                            k
                            m
                    Nothing -> m
            Year ->
                case Data.List.find (isInfixOf "year") (MMap.keys m) of
                    Just k -> MMap.alter (\(Just (BT.I year)) -> Just (BT.T (pack $ show (1970 + year)))) k m
                    Nothing -> m
            Hour ->
                case Data.List.find (isInfixOf "hour") (MMap.keys m) of
                    Just k -> do
                        let (Just (BT.I ts)) = MMap.lookup "b.timestamp" m
                        let (Just (BT.I mon)) = MMap.lookup "b.month" m
                        let (Just (BT.I hr)) = MMap.lookup "b.absoluteHour" m
                        let epd = utctDay $ posixSecondsToUTCTime 0
                        let cd = utctDay $ posixSecondsToUTCTime (fromIntegral ts)
                        let (_, day) = diffGregorianDurationClip cd epd
                        let years = 1970 + (div mon 12)
                        let month =
                                let x = Prelude.rem mon 12
                                 in if x == 0
                                        then 12
                                        else x
                        MMap.alter (const Nothing) "b.day" $
                            MMap.alter (const Nothing) "b.month" $
                            MMap.alter (const Nothing) "b.absoluteHour" $
                            MMap.alter
                                (\(Just (BT.I x)) ->
                                     Just
                                         (BT.T
                                              (pack $
                                               show (day + 1) <>
                                               "/" <> show month <> "/" <> show years <> " " <> show hr <> ":00:00")))
                                k
                                m
                    Nothing -> m

queryHandler :: QueryRequest -> Snap.Handler App App ()
queryHandler qr = do
    offset <- (flip (>>=) (TR.readMaybe . unpack . DTE.decodeUtf8)) <$> (getQueryParam "offset")
    limitv <- (flip (>>=) (TR.readMaybe . unpack . DTE.decodeUtf8)) <$> (getQueryParam "limit")
    let skip = " SKIP " <> (show $ fromMaybe 0 offset)
    let limit = " LIMIT " <> (show $ fromMaybe 200 limitv)
    case _where qr of
        Just (Object hm) -> do
            let groupeds =
                    case _return qr of
                        (Just (Object rh)) ->
                            case Map.lookup "$fields" rh of
                                (Just (Object x)) -> grouped <$> Map.keys x
                                _ -> []
                        _ -> []
            let resp =
                    BT.query $
                    (encodeQuery
                         hm
                         (_return qr)
                         (Map.insert "$fields" (Object (getMap $ catMaybes groupeds)) Map.empty)
                         (_on qr)) <>
                    (pack $ skip <> limit)
            dbe <- getDB
            pres <- liftIO $ try $ tryWithResource (pool $ graphDB dbe) (`BT.run` resp)
            case pres of
                Right rtm ->
                    case rtm of
                        Just rt ->
                            writeBS $ BSL.toStrict $ encode $ Prelude.foldr handleResponse rt (catMaybes groupeds)
                        Nothing -> writeBS $ BSL.toStrict $ encode rtm
                Left (e :: SomeException) -> throwBadRequest
        _ -> throwBadRequest
