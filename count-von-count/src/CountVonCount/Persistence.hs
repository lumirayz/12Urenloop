{-# LANGUAGE OverloadedStrings, ScopedTypeVariables #-}
module CountVonCount.Persistence
    ( Persistence
    , runPersistence

    , Ref
    , IsDocument (..)
    , put
    , get
    , add
    , getAll

    , Team (..)
    , Baton (..)
    ) where

import Control.Applicative ((<$>))
import Control.Arrow ((&&&))
import Control.Monad (void)
import Control.Monad.Trans (MonadIO, liftIO)

import qualified Data.ByteString as B
import qualified Data.CompactString.UTF8 as CSU
import qualified Database.MongoDB as MDB

type Persistence = MDB.Action IO

runPersistence :: MonadIO m => Persistence a -> m a
runPersistence p = liftIO $ do
    pipe <- MDB.runIOE $ MDB.connect $ MDB.host "127.0.0.1"
    x    <- MDB.access pipe MDB.master "count-von-count" p
    MDB.close pipe
    return $ either (error . show) id x

type Ref a = MDB.Value

class IsDocument a where
    collection   :: a -> MDB.Collection
    toDocument   :: a -> MDB.Document
    fromDocument :: MDB.Document -> a

add :: IsDocument d => d -> Persistence (Ref d)
add x = MDB.insert (collection x) $ toDocument x

put :: IsDocument d => Ref d -> d -> Persistence ()
put r x = void $ MDB.save (collection x) $ ("_id"  MDB.:= r) : toDocument x

get :: forall d. IsDocument d => Ref d -> Persistence d
get r = fromDocument <$>
    MDB.fetch (MDB.select ["_id" MDB.:= r] (collection x))
  where
    x = undefined :: d

getAll :: forall d. IsDocument d => Persistence [(Ref d, d)]
getAll = do
    cursor <- MDB.find $ MDB.select [] $ collection x
    docs   <- MDB.rest cursor
    return $ map (MDB.valueAt "_id" &&& fromDocument) docs
  where
    x = undefined :: d

data Team = Team
    { teamName  :: B.ByteString
    , teamLaps  :: Int
    , teamBaton :: Maybe (Ref Baton)
    } deriving (Eq, Show)

instance IsDocument Team where
    collection _     = "teams"
    toDocument team  =
        [ "name"  MDB.=: CSU.fromByteString_ (teamName team)
        , "laps"  MDB.=: teamLaps team
        , "baton" MDB.=: teamBaton team
        ]
    fromDocument doc = Team
        (CSU.toByteString $ MDB.at "name" doc)
        (MDB.at "laps" doc)
        (MDB.at "baton" doc)

data Baton = Baton
    { batonNr   :: Int
    , batonMac  :: B.ByteString
    , batonTeam :: Maybe (Ref Team)
    } deriving (Eq, Show)

instance IsDocument Baton where
    collection _     = "batons"
    toDocument baton =
        [ "nr"   MDB.=: batonNr baton
        , "mac"  MDB.=: CSU.fromByteString_ (batonMac baton)
        , "team" MDB.=: batonTeam baton
        ]
    fromDocument doc            = Baton
        (MDB.at "nr" doc)
        (CSU.toByteString $ MDB.at "mac" doc)
        (MDB.at "team" doc)
