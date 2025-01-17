{-# LANGUAGE GADTs #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Flora.Model.Job where

import Data.Aeson
import Data.Text (Text)
import Data.Text.Display
import Distribution.Pretty
import Distribution.Version (Version, mkVersion, versionNumbers)
import GHC.Generics (Generic)
import OddJobs.Job (Job, LogEvent (..))
import OddJobs.Types (FailureMode)
import Servant (ToHttpApiData)

import Data.Vector (Vector)
import Flora.Import.Package.Types (ImportOutput)
import Flora.Model.Package (PackageName (..))
import Flora.Model.Release.Types (ReleaseId (..))

newtype IntAesonVersion = MkIntAesonVersion {unIntAesonVersion :: Version}
  deriving
    (Pretty, ToHttpApiData, Display)
    via Version

instance ToJSON IntAesonVersion where
  toJSON (MkIntAesonVersion x) = toJSON $! versionNumbers x

instance FromJSON IntAesonVersion where
  parseJSON val = MkIntAesonVersion . mkVersion <$> parseJSON val

data ReadmeJobPayload = ReadmeJobPayload
  { mpPackage :: PackageName
  , mpReleaseId :: ReleaseId -- needed to write the readme in db
  , mpVersion :: IntAesonVersion
  }
  deriving stock (Generic)
  deriving anyclass (ToJSON, FromJSON)

data UploadTimeJobPayload = UploadTimeJobPayload
  { packageName :: PackageName
  , releaseId :: ReleaseId
  , packageVersion :: IntAesonVersion
  }
  deriving stock (Generic)
  deriving anyclass (ToJSON, FromJSON)

data ChangelogJobPayload = ChangelogJobPayload
  { packageName :: PackageName
  , releaseId :: ReleaseId
  , packageVersion :: IntAesonVersion
  }
  deriving stock (Generic)
  deriving anyclass (ToJSON, FromJSON)

data ImportHackageIndexPayload = ImportHackageIndexPayload
  deriving stock (Generic)
  deriving anyclass (ToJSON, FromJSON)

-- these represent the possible odd jobs we can run.
data FloraOddJobs
  = FetchReadme ReadmeJobPayload
  | FetchUploadTime UploadTimeJobPayload
  | FetchChangelog ChangelogJobPayload
  | ImportHackageIndex ImportHackageIndexPayload
  | ImportPackage ImportOutput
  | FetchPackageDeprecationList
  | FetchReleaseDeprecationList PackageName (Vector ReleaseId)
  | RefreshLatestVersions
  deriving stock (Generic)
  deriving anyclass (ToJSON, FromJSON)

-- TODO: Upstream these two ToJSON instances
deriving instance ToJSON FailureMode
deriving instance ToJSON Job

instance ToJSON LogEvent where
  toJSON = \case
    LogJobStart job -> toJSON ("start" :: Text, job)
    LogJobSuccess job time -> toJSON ("success" :: Text, job, time)
    LogJobFailed job exception failuremode finishTime ->
      toJSON ("failed" :: Text, show exception, job, failuremode, finishTime)
    LogJobTimeout job -> toJSON ("timed-out" :: Text, job)
    LogPoll -> toJSON ("poll" :: Text)
    LogWebUIRequest -> toJSON ("web-ui-request" :: Text)
    LogText other -> toJSON ("other" :: Text, other)
