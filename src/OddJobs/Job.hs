{-# LANGUAGE RankNTypes, FlexibleInstances, FlexibleContexts, PartialTypeSignatures, TupleSections, DeriveGeneric, UndecidableInstances #-}
module OddJobs.Job
  ( jobMonitor
  , jobEventListener
  , jobPoller
  , createJob
  , scheduleJob
  , Job(..)
  , JobRunner
  , HasJobMonitor(..)
  , Status(..)
  , findJobById
  , findJobByIdIO
  , JobId
  , saveJob
  , saveJobIO
  , defaultPollingInterval
  , JobMonitor(..)
  , defaultJobMonitor
  , runJobMonitor
  , TableName
  , jobDbColumns
  , concatJobDbColumns
  , jobType
  , delaySeconds
  , Seconds(..)
  )
where

import OddJobs.Types
import Data.Pool
import Data.Text as T
import Database.PostgreSQL.Simple as PGS
import Database.PostgreSQL.Simple.Notification
import Database.PostgreSQL.Simple.FromField as FromField
import Database.PostgreSQL.Simple.ToField as ToField
import Database.PostgreSQL.Simple.FromRow as FromRow
import UnliftIO.Async
import Control.Concurrent.Async (AsyncCancelled(..))
import UnliftIO.Concurrent (threadDelay, myThreadId)
import Data.String
import System.Posix.Process (getProcessID)
import Network.HostName (getHostName)
import UnliftIO.MVar
import Debug.Trace
import Control.Monad.Logger as MLogger
import UnliftIO.IORef
import UnliftIO.Exception (SomeException(..), try, catch, finally, catchAny, bracket, Exception(..), throwIO, catches, Handler(..), mask_)
import Data.Proxy
import Control.Monad.Trans.Control
import Control.Monad.IO.Unlift (MonadUnliftIO, withRunInIO, liftIO)
import Data.Text.Conversions
import Data.Time
import Data.Aeson hiding (Success)
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Types as Aeson (Parser, parseMaybe)
import Data.String.Conv (StringConv(..), toS)
import Data.Functor (void)
import Control.Monad (forever)
import Data.Maybe (isNothing)
import Data.Either (either)
-- import System.Log.FastLogger (fromLogStr, newTimedFastLogger, LogType(..), defaultBufSize, FastLogger, FileLogSpec(..), TimedFastLogger)
-- import System.Log.FastLogger.Date (newTimeCache, simpleTimeFormat')
import Control.Monad.Reader
import GHC.Generics
import qualified Data.HashMap.Strict as HM
import qualified Data.List as DL

class (MonadUnliftIO m, MonadBaseControl IO m, MonadLogger m) => HasJobMonitor m where
  getPollingInterval :: m Seconds
  onJobSuccess :: Job -> m ()
  onJobFailed :: Job -> m ()
  onJobPermanentlyFailed :: Job -> m ()
  getJobRunner :: m (Job -> IO ())
  getMaxAttempts :: m Int
  getDbPool :: m (Pool Connection)
  getTableName :: m TableName
  onJobStart :: Job -> m ()
  getDefaultMaxAttempts :: m Int
  onJobTimeout :: Job -> m ()
  getMonitorEnv :: m MonitorEnv
  getConcurrencyControl :: m ConcurrencyControl

data JobMonitor = JobMonitor
  { monitorPollingInterval :: Seconds
  , monitorOnJobSuccess :: Job -> IO ()
  , monitorOnJobFailed :: Job -> IO ()
  , monitorOnJobPermanentlyFailed :: Job -> IO ()
  , monitorOnJobStart :: Job -> IO ()
  , monitorOnJobTimeout :: Job -> IO ()
  , monitorJobRunner :: Job -> IO ()
  , monitorMaxAttempts :: Int
  , monitorLogger :: Loc -> LogSource -> LogLevel -> LogStr -> IO ()
  , monitorDbPool :: Pool Connection
  , monitorTableName :: TableName
  , monitorDefaultMaxAttempts :: Int
  , monitorConcurrencyControl :: ConcurrencyControl
  }

data ConcurrencyControl = MaxConcurrentJobs Int
                        | UnlimitedConcurrentJobs
                        | DynamicConcurrency (IO Bool)

data MonitorEnv = MonitorEnv
  { envConfig :: JobMonitor
  , envJobThreadsRef :: IORef [Async ()]
  }

type JobMonitorM = ReaderT MonitorEnv IO

instance {-# OVERLAPS #-} MonadLogger JobMonitorM where
  monadLoggerLog loc logsource loglevel msg = do
    fn <- monitorLogger . envConfig <$> ask
    liftIO $ fn loc logsource loglevel (toLogStr msg)


logCallbackErrors :: (HasJobMonitor m) => JobId -> Text -> m () -> m ()
logCallbackErrors jid msg action = catchAny action $ \e -> logErrorN $ msg <> " Job ID=" <> toS (show jid) <> ": " <> toS (show e)

instance HasJobMonitor JobMonitorM where
  getPollingInterval = monitorPollingInterval . envConfig <$> ask
  onJobFailed job = do
    fn <- monitorOnJobFailed . envConfig  <$> ask
    logCallbackErrors (jobId job) "onJobFailed" $ liftIO $ fn job
  onJobSuccess job = do
    fn <- monitorOnJobSuccess . envConfig <$> ask
    logCallbackErrors (jobId job) "onJobSuccess" $ liftIO $ fn job
  onJobPermanentlyFailed job = do
    fn <- monitorOnJobPermanentlyFailed . envConfig <$> ask
    logCallbackErrors (jobId job) "onJobPermanentlyFailed" $ liftIO $ fn job
  getJobRunner = monitorJobRunner . envConfig <$> ask
  getMaxAttempts = monitorMaxAttempts . envConfig <$> ask
  getDbPool = monitorDbPool . envConfig <$> ask
  getTableName = monitorTableName . envConfig <$> ask
  onJobStart job = do
    fn <- monitorOnJobStart . envConfig <$> ask
    logCallbackErrors (jobId job) "onJobStart" $ liftIO $ fn job

  onJobTimeout job = do
    fn <- monitorOnJobTimeout . envConfig <$> ask
    logCallbackErrors (jobId job) "onJobTimeout" $ liftIO $ fn job

  getDefaultMaxAttempts = monitorDefaultMaxAttempts . envConfig <$> ask

  getMonitorEnv = ask

  getConcurrencyControl = (monitorConcurrencyControl . envConfig <$> ask)



runJobMonitor :: JobMonitor -> IO ()
runJobMonitor jm = do
  r <- newIORef []
  let monitorEnv = MonitorEnv
                   { envConfig = jm
                   , envJobThreadsRef = r
                   }
  runReaderT jobMonitor monitorEnv

defaultJobMonitor :: (Loc -> LogSource -> LogLevel -> LogStr -> IO ())
                  -> TableName
                  -> Pool Connection
                  -> JobMonitor
defaultJobMonitor logger tname dbpool = JobMonitor
  { monitorPollingInterval = defaultPollingInterval
  , monitorOnJobSuccess = (const $ pure ())
  , monitorOnJobFailed = (const $ pure ())
  , monitorOnJobPermanentlyFailed = (const $ pure ())
  , monitorJobRunner = (const $ pure ())
  , monitorMaxAttempts = 25
  , monitorLogger = logger
  , monitorDbPool = dbpool
  , monitorOnJobStart = (const $ pure ())
  , monitorDefaultMaxAttempts = 10
  , monitorTableName = tname
  , monitorOnJobTimeout = (const $ pure ())
  }


oneSec :: Int
oneSec = 1000000

defaultPollingInterval :: Seconds
defaultPollingInterval = Seconds 5

type JobId = Int

data Status = Success
            | Queued
            | Failed
            | Retry
            | Locked
            deriving (Eq, Show, Generic, Enum)

instance Ord Status where
  compare x y = compare (toText x) (toText y)

data Job = Job
  { jobId :: JobId
  , jobCreatedAt :: UTCTime
  , jobUpdatedAt :: UTCTime
  , jobRunAt :: UTCTime
  , jobStatus :: Status
  , jobPayload :: Value
  , jobLastError :: Maybe Value
  , jobAttempts :: Int
  , jobLockedAt :: Maybe UTCTime
  , jobLockedBy :: Maybe Text
  } deriving (Eq, Show)

instance ToText Status where
  toText s = case s of
    Success -> "success"
    Queued -> "queued"
    Retry -> "retry"
    Failed -> "failed"
    Locked -> "locked"

instance (StringConv Text a) => FromText (Either a Status) where
  fromText t = case t of
    "success" -> Right Success
    "queued" -> Right Queued
    "failed" -> Right Failed
    "retry" -> Right Retry
    "locked" -> Right Locked
    x -> Left $ toS $ "Unknown job status: " <> x

instance FromField Status where
  fromField f mBS = (fromText <$> (fromField f mBS)) >>= \case
    Left e -> FromField.returnError PGS.ConversionFailed f e
    Right s -> pure s

instance ToField Status where
  toField s = toField $ toText s

instance FromRow Job where
  fromRow = Job
    <$> field -- jobId
    <*> field -- createdAt
    <*> field -- updatedAt
    <*> field -- runAt
    <*> field -- status
    <*> field -- payload
    <*> field -- lastError
    <*> field -- attempts
    <*> field -- lockedAt
    <*> field -- lockedBy

-- TODO: Add a sum-type for return status which can signal the monitor about
-- whether the job needs to be retried, marked successfull, or whether it has
-- completed failed.
type JobRunner = Job -> IO ()


jobWorkerName :: IO String
jobWorkerName = do
  pid <- getProcessID
  hname <- getHostName
  pure $ (show hname) ++ ":" ++ (show pid)

-- TODO: Make this configurable based on a per-job basis
lockTimeout :: Seconds
lockTimeout = Seconds 600

delaySeconds :: (MonadIO m) => Seconds -> m ()
delaySeconds (Seconds s) = threadDelay $ oneSec * s

jobDbColumns :: (IsString s, Semigroup s) => [s]
jobDbColumns =
  [ "id"
  , "created_at"
  , "updated_at"
  , "run_at"
  , "status"
  , "payload"
  , "last_error"
  , "attempts"
  , "locked_at"
  , "locked_by"
  ]

concatJobDbColumns :: (IsString s, Semigroup s) => s
concatJobDbColumns = concatJobDbColumns_ jobDbColumns ""
  where
    concatJobDbColumns_ [] x = x
    concatJobDbColumns_ (col:[]) x = x <> col
    concatJobDbColumns_ (col:cols) x = concatJobDbColumns_ cols (x <> col <> ", ")


findJobByIdQuery :: TableName -> PGS.Query
findJobByIdQuery tname = "SELECT " <> concatJobDbColumns <> " FROM " <> tname <> " WHERE id = ?"

withDbConnection :: (HasJobMonitor m)
                 => (Connection -> m a)
                 -> m a
withDbConnection action = do
  pool <- getDbPool
  withResource pool action

findJobById :: (HasJobMonitor m)
            => JobId
            -> m (Maybe Job)
findJobById jid = do
  tname <- getTableName
  withDbConnection $ \conn -> liftIO $ findJobByIdIO conn tname jid

findJobByIdIO :: Connection -> TableName -> JobId -> IO (Maybe Job)
findJobByIdIO conn tname jid = PGS.query conn (findJobByIdQuery tname) (Only jid) >>= \case
  [] -> pure Nothing
  [j] -> pure (Just j)
  js -> Prelude.error $ "Not expecting to find multiple jobs by id=" <> (show jid)


saveJobQuery :: TableName -> PGS.Query
saveJobQuery tname = "UPDATE " <> tname <> " set run_at = ?, status = ?, payload = ?, last_error = ?, attempts = ?, locked_at = ?, locked_by = ? WHERE id = ? RETURNING " <> concatJobDbColumns


saveJob :: (HasJobMonitor m) => Job -> m Job
saveJob j = do
  tname <- getTableName
  withDbConnection $ \conn -> liftIO $ saveJobIO conn tname j

saveJobIO :: Connection -> TableName -> Job -> IO Job
saveJobIO conn tname Job{jobRunAt, jobStatus, jobPayload, jobLastError, jobAttempts, jobLockedBy, jobLockedAt, jobId} = do
  rs <- PGS.query conn (saveJobQuery tname)
        ( jobRunAt
        , jobStatus
        , jobPayload
        , jobLastError
        , jobAttempts
        , jobLockedAt
        , jobLockedBy
        , jobId
        )
  case rs of
    [] -> Prelude.error $ "Could not find job while updating it id=" <> (show jobId)
    [j] -> pure j
    js -> Prelude.error $ "Not expecting multiple rows to ber returned when updating job id=" <> (show jobId)

data TimeoutException = TimeoutException deriving (Eq, Show)
instance Exception TimeoutException

runJobWithTimeout :: (HasJobMonitor m)
                  => Seconds
                  -> Job
                  -> m ()
runJobWithTimeout timeoutSec job = do
  threadsRef <- envJobThreadsRef <$> getMonitorEnv
  jobRunner_ <- getJobRunner

  a <- async $ liftIO $ jobRunner_ job

  x <- atomicModifyIORef' threadsRef $ \threads -> (a:threads, DL.map asyncThreadId (a:threads))
  -- liftIO $ putStrLn $ "Threads: " <> show x
  logDebugN $ toS $ "Spawned job in " <> show (asyncThreadId a)

  t <- async $ do
    delaySeconds timeoutSec
    uninterruptibleCancel a
    throwIO TimeoutException

  void $ finally
    (waitEitherCancel a t)
    (atomicModifyIORef' threadsRef $ \threads -> (DL.delete a threads, ()))


runJob :: (HasJobMonitor m) => JobId -> m ()
runJob jid =
  (findJobById jid) >>= \case
    Nothing -> Prelude.error $ "Could not find job id=" <> show jid
    Just job -> (flip catches) [Handler $ timeoutHandler job, Handler $ exceptionHandler job] $ do
      runJobWithTimeout lockTimeout job
      newJob <- saveJob job{jobStatus=Success, jobLockedBy=Nothing, jobLockedAt=Nothing}
      onJobSuccess newJob
      pure ()
  where
    timeoutHandler job (e :: TimeoutException) = retryOrFail (show e) job onJobTimeout onJobPermanentlyFailed
    exceptionHandler job (e :: SomeException) = retryOrFail (show e) job onJobFailed onJobPermanentlyFailed
    retryOrFail errStr job onFail onPermanentFail = do
      defaultMaxAttempts <- getDefaultMaxAttempts
      let (newStatus, action) = if (jobAttempts job) >= defaultMaxAttempts
                                then (Failed, onPermanentFail)
                                else (Retry, onFail)
      t <- liftIO getCurrentTime
      newJob <- saveJob job{ jobStatus=newStatus
                           , jobLockedBy=Nothing
                           , jobLockedAt=Nothing
                           , jobLastError=(Just $ toJSON errStr) -- TODO: convert errors to json properly
                           , jobRunAt=(addUTCTime (fromIntegral $ (1::Int) ^ (jobAttempts job)) t)
                           }
      void $ action newJob
      pure ()


restartUponCrash :: (HasJobMonitor m, Show a) => Text -> m a -> m ()
restartUponCrash name_ action = do
  a <- async action
  finally (waitCatch a >>= fn) $ do
    (liftIO $ putStrLn $ "Received shutdown: " <> toS name_)
    cancel a
  where
    fn x = do
      case x of
        Left (e :: SomeException) -> liftIO $ putStrLn $ toS $ name_ <> " seems to have exited with an error. Restarting: " <> toS (show e)
        Right r -> liftIO $ putStrLn  $ toS $ name_ <> " seems to have exited with the folloing result: " <> toS (show r) <> ". Restaring."
      restartUponCrash name_ action

jobMonitor :: forall m . (HasJobMonitor m) => m ()
jobMonitor = do
  a1 <- async $ restartUponCrash "Job poller" jobPoller
  a2 <- async $ restartUponCrash "Job event listener" jobEventListener
  finally (void $ waitAnyCatch [a1, a2]) $ do
    liftIO $ putStrLn "Stopping jobPoller and jobEventListener threads."
    logInfoN "Stopping jobPoller and jobEventListener threads."
    cancel a2
    cancel a1
    liftIO $ putStrLn "Waiting for jobs to complete."
    logInfoN "Waiting for job complete."
    waitForJobs
    liftIO $ putStrLn "STOPPED jobPoller and jobEventListener threads."

  -- threadsRef <- newIORef []
  -- jobMonitor_ threadsRef Nothing Nothing Nothing
  -- where
  --   jobMonitor_ :: IORef [Async ()] -> Maybe (Async ()) -> Maybe (Async ()) -> Maybe (Async ()) -> m ()
  --   jobMonitor_ threadsRef mPollerAsync mEventAsync mThreadMonitorAsync = do
  --     pollerAsync <- maybe (async $ jobPoller threadsRef) pure mPollerAsync
  --     eventAsync <- maybe (async $ jobEventListener threadsRef) pure mEventAsync
  --     threadMonitorAsync <- maybe (async $ threadMonitor threadsRef) pure mThreadMonitorAsync
  --     finally
  --       (restartUponCrash threadsRef pollerAsync eventAsync threadMonitorAsync)
  --       (do logInfoN "Received shutdown event. Cancelling job-poller and event-listener threads"
  --           cancel eventAsync
  --           cancel pollerAsync
  --           cancel threadMonitorAsync
  --       )


  --   restartUponCrash threadsRef pollerAsync eventAsync threadMonitorAsync = do
  --     (t, result) <- waitAnyCatch [pollerAsync, eventAsync, threadMonitorAsync]
  --     if t==pollerAsync
  --       then do either
  --                 (\(SomeException e) -> logErrorN $ "Job poller seems to have crashed. Respawning: " <> toS (show e))
  --                 (\x -> logErrorN $ "Job poller seems to have escaped the `forever` loop. Respawning: " <> toS (show x))
  --                 result
  --               jobMonitor_ threadsRef Nothing (Just eventAsync) (Just threadMonitorAsync)
  --       else if t==eventAsync
  --            then do either
  --                      (\(SomeException e) -> logErrorN $ "Event listener seems to have crashed. Respawning: " <> toS (show e))
  --                      (\x -> logErrorN $ "Event listener seems to have escaped the `forever` loop. Respawning: " <> toS (show x))
  --                      result
  --                    jobMonitor_ threadsRef (Just pollerAsync) Nothing (Just threadMonitorAsync)
  --            else if t==threadMonitorAsync
  --                 then do either
  --                           (\(SomeException e) -> logErrorN $ "Thread monitor seems to have crashed. Respawning: " <> toS (show e))
  --                           (\x -> logErrorN $ "Thread monitor seems to have escaped the `forever` loop. Respawning: " <> toS (show x))
  --                           result
  --                         jobMonitor_ threadsRef (Just pollerAsync) (Just eventAsync) Nothing
  --                 else logErrorN "Impossible happened. One of the three top-level threads/asyncs crashed but we were unable to figure out which one."

jobPollingSql :: TableName -> Query
jobPollingSql tname = "update " <> tname <> " set status = ?, locked_at = ?, locked_by = ?, attempts=attempts+1 WHERE id in (select id from " <> tname <> " where (run_at<=? AND ((status in ?) OR (status = ? and locked_at<?))) ORDER BY run_at ASC LIMIT 1 FOR UPDATE) RETURNING id"

waitForJobs :: (HasJobMonitor m)
            => m ()
waitForJobs = do
  threadsRef <- envJobThreadsRef <$> getMonitorEnv
  readIORef threadsRef >>= \case
    [] -> liftIO $ putStrLn "Jobs stopped."
    as -> do
      tid <- myThreadId
      (a, _) <- waitAnyCatch as
      liftIO $ putStrLn $ "Job complete: " <> show (asyncThreadId a)
      liftIO $ putStrLn $ "Waiting for " <> show (DL.length as) <> " jobs to complete before shutting down. myThreadId=" <> (show tid)
      delaySeconds (Seconds 1)
      waitForJobs


  -- finally threadMonitor_ $ do
  -- timeoutThread <- async timeout
  -- waitForCompletion timeoutThread
  -- where
  --   waitForCompletion timeoutThread = readIORef threadsRef >>= \case
  --     [] -> do
  --       logDebugN "No job threads running."
  --     threads -> do
  --       logDebugN $ toS $ "Waiting for " <> show (DL.length threads) <> " to complete..."
  --       (thread, _) <- waitAnyCatch threads
  --       removeThreadRef thread
  --       waitForCompletion timeoutThread

  --   timeout = do
  --     delaySeconds lockTimeout
  --     logDebugN "===> Timeout has expired. Forcefulling cancelling all job-threads now. <==="
  --     mapM_ uninterruptibleCancel =<< (readIORef threadsRef)

  --   threadMonitor_ =  forever $ readIORef threadsRef >>= \case
  --     [] -> delaySeconds =<< getPollingInterval
  --     threads -> do
  --       logDebugN $ toS $ "Waiting on job threads: " <> show (DL.length threads) <> " threads"
  --       (thread, ret) <- waitAnyCatch threads
  --       let tid = asyncThreadId thread
  --       logDebugN $ toS $ "Thread finished " <> show tid <> ". Result: " <> show ret
  --       removeThreadRef thread

  --   removeThreadRef thread = atomicModifyIORef' threadsRef $ \threads -> (DL.delete thread threads, ())

-- withThreadAccounting :: (HasJobMonitor m)
--                      => m a
--                      -> m (Async a)
-- withThreadAccounting action = do
--   threadsRef <- envJobThreadsRef <$> getMonitorEnv
--   mv <- newEmptyMVar
--   a <- async $ do
--     takeMVar mv
--     action
--   atomicModifyIORef' threadsRef $ \threads -> (a:threads, ())
--   putMVar mv ()
--   pure a

getConcurrencyControlFn :: (HasJobMonitor m)
                        => m (m Bool)
getConcurrencyControlFn = getConcurrencyControl >>= \case
  UnlimitedConcurrentJobs -> pure $ pure True
  MaxConcurrentJobs maxJobs -> pure $ do
    curJobs <- getMonitorEnv >>= (readIORef . envJobThreadsRef)
    pure $ (DL.length curJobs) < maxJobs
  DynamicConcurrency fn -> pure $ liftIO fn

jobPoller :: (HasJobMonitor m) => m ()
jobPoller = do
  processName <- liftIO jobWorkerName
  pool <- getDbPool
  tname <- getTableName
  logInfoN $ toS $ "Starting the job monitor via DB polling with processName=" <> show processName
  concurrencyControlFn <- getConcurrencyControlFn
  withResource pool $ \pollerDbConn -> forever $ concurrencyControlFn >>= \case
    False -> logInfoN $ "NOT polling the job queue due to concurrency control"
    True -> do
      nextAction <- mask_ $ do
        logInfoN $ toS $ "[" <> show processName <> "] Polling the job queue.."
        t <- liftIO getCurrentTime
        r <- liftIO $
             PGS.query pollerDbConn (jobPollingSql tname)
             (Locked, t, processName, t, (In [Queued, Retry]), Locked, (addUTCTime (fromIntegral $ negate $ unSeconds lockTimeout) t))
        case r of
          -- When we don't have any jobs to run, we can relax a bit...
          [] -> pure delayAction

          -- When we find a job to run, fork and try to find the next job without any delay...
          [Only (jid :: JobId)] -> do
            void $ async $ runJob jid
            pure noDelayAction

          x -> error $ "WTF just happened? I was supposed to get only a single row, but got: " ++ (show x)
      nextAction
  where
    delayAction = delaySeconds =<< getPollingInterval
    noDelayAction = pure ()

jobEventListener :: (HasJobMonitor m)
                 => m ()
jobEventListener = do
  logInfoN "Starting the job monitor via LISTEN/NOTIFY..."
  pool <- getDbPool
  tname <- getTableName
  jwName <- liftIO jobWorkerName
  concurrencyControlFn <- getConcurrencyControlFn

  let tryLockingJob jid = do
        let q = "UPDATE " <> tname <> " SET status=?, locked_at=now(), locked_by=?, attempts=attempts+1 WHERE id=? AND status in ? RETURNING id"
        (withDbConnection $ \conn -> (liftIO $ PGS.query conn q (Locked, jwName, jid, In [Queued, Retry]))) >>= \case
          [] -> do
            logDebugN $ toS $ "Job was locked by someone else before I could start. Skipping it. JobId=" <> show jid
            pure Nothing
          [Only (_ :: JobId)] -> pure $ Just jid
          x -> error $ "WTF just happned? Was expecting a single row to be returned, received " ++ (show x)

  withResource pool $ \monitorDbConn -> do
    void $ liftIO $ PGS.execute monitorDbConn ("LISTEN " <> pgEventName tname) ()
    forever $ do
      logInfoN "[LISTEN/NOFIFY] Event loop"
      notif <- liftIO $ getNotification monitorDbConn
      concurrencyControlFn >>= \case
        False -> logInfoN $ "Received job event, but ignoring it due to concurrency control"
        True -> do
          let pload = notificationData notif
          logDebugN $ toS $ "NOTIFY | " <> show pload
          case (eitherDecode $ toS pload) of
            Left e -> logErrorN $ toS $  "Unable to decode notification payload received from Postgres. Payload=" <> show pload <> " Error=" <> show e

            -- Checking if job needs to be fired immediately AND it is not already
            -- taken by some othe thread, by the time it got to us
            Right (v :: Value) -> case (Aeson.parseMaybe parser v) of
              Nothing -> logErrorN $ toS $ "Unable to extract id/run_at/locked_at from " <> show pload
              Just (jid, runAt_, mLockedAt_) -> do
                t <- liftIO getCurrentTime
                if (runAt_ <= t) && (isNothing mLockedAt_)
                  then do logDebugN $ toS $ "Job needs needs to be run immediately. Attempting to fork in background. JobId=" <> show jid
                          void $ async $ do
                            -- Let's try to lock the job first... it is possible that it has already
                            -- been picked up by the poller by the time we get here.
                            tryLockingJob jid >>= \case
                              Nothing -> pure ()
                              Just lockedJid -> runJob lockedJid
                  else logDebugN $ toS $ "Job is either for future, or is already locked. Skipping. JobId=" <> show jid
  where
    parser :: Value -> Aeson.Parser (JobId, UTCTime, Maybe UTCTime)
    parser = withObject "expecting an object to parse job.run_at and job.locked_at" $ \o -> do
      runAt_ <- o .: "run_at"
      mLockedAt_ <- o .:? "locked_at"
      jid <- o .: "id"
      pure (jid, runAt_, mLockedAt_)



createJobQuery :: TableName -> PGS.Query
createJobQuery tname = "INSERT INTO " <> tname <> "(run_at, status, payload, last_error, attempts, locked_at, locked_by) VALUES (?, ?, ?, ?, ?, ?, ?) RETURNING " <> concatJobDbColumns

createJob :: ToJSON p => Connection -> TableName -> p -> IO Job
createJob conn tname payload = do
  t <- getCurrentTime
  scheduleJob conn tname payload t

scheduleJob :: ToJSON p => Connection -> TableName -> p -> UTCTime -> IO Job
scheduleJob conn tname payload runAt = do
  let args = ( runAt, Queued, toJSON payload, Nothing :: Maybe Value, 0 :: Int, Nothing :: Maybe Text, Nothing :: Maybe Text )
      queryFormatter = toS <$> (PGS.formatQuery conn (createJobQuery tname) args)
  rs <- PGS.query conn (createJobQuery tname) args
  case rs of
    [] -> (Prelude.error . (<> "Not expecting a blank result set when creating a job. Query=")) <$> queryFormatter
    [r] -> pure r
    _ -> (Prelude.error . (<> "Not expecting multiple rows when creating a single job. Query=")) <$> queryFormatter 


jobType :: Job -> T.Text
jobType Job{jobPayload} = case jobPayload of
  Aeson.Object hm -> case HM.lookup "tag" hm of
    Just (Aeson.String t) -> t
    _ -> ""
  _ -> ""


-- getMonitorEnv :: (HasJobMonitor m) => m MonitorEnv
-- getMonitorEnv = ask

