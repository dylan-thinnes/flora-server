module Flora.Model.Package.Types where

import Control.DeepSeq
import Crypto.Hash.MD5 qualified as MD5
import Data.Aeson
import Data.Aeson.Orphans ()
import Data.ByteString (ByteString)
import Data.ByteString.Lazy (fromStrict)
import Data.Maybe (fromJust, fromMaybe)
import Data.Text (Text, isPrefixOf, unpack)
import Data.Text qualified as Text
import Data.Text.Display
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Data.Time (UTCTime)
import Data.UUID
import Database.PostgreSQL.Entity.Types
import Database.PostgreSQL.Simple.FromField (FromField (..), ResultError (ConversionFailed, UnexpectedNull), fromJSONField, returnError)
import Database.PostgreSQL.Simple.FromRow (FromRow (..))
import Database.PostgreSQL.Simple.Newtypes (Aeson (..))
import Database.PostgreSQL.Simple.ToField (Action (Escape), ToField (..), toJSONField)
import Database.PostgreSQL.Simple.ToRow (ToRow (..))
import Distribution.Pretty (Pretty (..))
import GHC.Generics
import Language.Souffle.Interpreted qualified as Souffle
import Lucid
import Servant (FromHttpApiData (..))
import Text.PrettyPrint qualified as PP
import Text.Regex.Pcre2
import Web.HttpApiData (ToHttpApiData (..))

import Data.Vector (Vector)
import Distribution.Orphans ()
import Distribution.SPDX.License qualified as SPDX
import Distribution.Types.Version (Version)
import Flora.Model.Package.Orphans ()
import Flora.Model.User

newtype PackageId = PackageId {getPackageId :: UUID}
  deriving stock (Generic)
  deriving
    (Eq, Ord, Show, FromField, ToField, FromJSON, ToJSON, ToHttpApiData, FromHttpApiData, NFData)
    via UUID
  deriving
    (Display)
    via ShowInstance UUID

-- | Generates a package id deterministically by hashing the namespace and the package name
deterministicPackageId :: Namespace -> PackageName -> PackageId
deterministicPackageId (Namespace ns) (PackageName name) =
  PackageId . fromJust . fromByteString . fromStrict . MD5.hash . encodeUtf8 $! ns <> name

newtype PackageName = PackageName Text
  deriving stock (Show, Generic)
  deriving anyclass (Souffle.Marshal)
  deriving
    (Eq, Ord, FromJSON, ToJSON, FromField, ToField, ToHtml, ToHttpApiData, NFData)
    via Text

instance Pretty PackageName where
  pretty (PackageName txt) = PP.text $! unpack txt

instance Display PackageName where
  displayBuilder (PackageName name) = displayBuilder name

instance FromHttpApiData PackageName where
  parseUrlPiece piece =
    case parsePackageName piece of
      Nothing -> Left "Could not parse package name"
      Just a -> Right a

parsePackageName :: Text -> Maybe PackageName
parsePackageName txt =
  if matches "[[:digit:]]*[[:alpha:]][[:alnum:]]*(-[[:digit:]]*[[:alpha:]][[:alnum:]]*)*" txt
    then Just $! PackageName txt
    else Nothing

newtype Namespace = Namespace Text
  deriving stock (Show)
  deriving
    (Eq, Ord, FromJSON, ToJSON, ToHtml, NFData)
    via Text

instance ToField Namespace where
  toField (Namespace txt) = toField $! fromMaybe txt (Text.stripPrefix "@" txt)

instance FromField Namespace where
  fromField f dat = do
    (rawField :: Text) <- fromField f dat
    pure $! Namespace rawField

instance Pretty Namespace where
  pretty (Namespace txt) = PP.text $! unpack txt

instance Display Namespace where
  displayBuilder (Namespace name) =
    if "@" `isPrefixOf` name
      then displayBuilder name
      else "@" <> displayBuilder name

instance ToHttpApiData Namespace where
  toUrlPiece (Namespace ns) =
    if "@" `isPrefixOf` ns
      then ns
      else "@" <> ns

instance FromHttpApiData Namespace where
  parseUrlPiece piece =
    case parseNamespace piece of
      Nothing -> Left "Could not parse namespace"
      Just a -> Right a

parseNamespace :: Text -> Maybe Namespace
parseNamespace txt =
  if matches "@[[:digit:]]*[[:alpha:]][[:alnum:]]*(-[[:digit:]]*[[:alpha:]][[:alnum:]]*)*" txt
    then Just $! Namespace txt
    else Nothing

data PackageStatus = UnknownPackage | FullyImportedPackage
  deriving stock (Eq, Show, Generic, Bounded, Enum, Ord)
  deriving anyclass (ToJSON, FromJSON, NFData)

parsePackageStatus :: ByteString -> Maybe PackageStatus
parsePackageStatus "unknown" = pure UnknownPackage
parsePackageStatus "fully-imported" = pure FullyImportedPackage
parsePackageStatus _ = Nothing

instance Display PackageStatus where
  displayBuilder UnknownPackage = "unknown"
  displayBuilder FullyImportedPackage = "fully-imported"

instance FromField PackageStatus where
  fromField f Nothing = returnError UnexpectedNull f ""
  fromField _ (Just bs) | Just status <- parsePackageStatus bs = pure status
  fromField f (Just bs) =
    returnError ConversionFailed f $
      unpack $
        "Conversion error: Expected component to be one of "
          <> display @[PackageStatus] [minBound .. maxBound]
          <> ", but instead got "
          <> decodeUtf8 bs

instance ToField PackageStatus where
  toField = Escape . encodeUtf8 . display

data Package = Package
  { packageId :: PackageId
  , namespace :: Namespace
  , name :: PackageName
  , ownerId :: UserId
  , createdAt :: UTCTime
  , updatedAt :: UTCTime
  , status :: PackageStatus
  , metadata :: PackageMetadata
  }
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromRow, ToRow, ToJSON, FromJSON, NFData)
  deriving
    (Entity)
    via (GenericEntity '[TableName "packages"] Package)

data PackageMetadata = PackageMetadata
  { deprecationInfo :: Maybe (Vector PackageAlternative)
  }
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON, NFData)

instance FromField PackageMetadata where
  fromField = fromJSONField

instance ToField PackageMetadata where
  toField = toJSONField

data Dependent = Dependent
  { name :: Text
  , namespace :: Text
  , dependentId :: PackageId
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromRow, ToRow, NFData)
  deriving
    (Entity)
    via (GenericEntity '[TableName "dependents"] Dependent)

{-| A record specifically crafted for
 templates usage.
-}
data PackageInfo = PackageInfo
  { namespace :: Namespace
  , name :: PackageName
  , synopsis :: Text
  , version :: Version
  , license :: SPDX.License
  , rating :: Maybe Double
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromRow, NFData)

-- DTO that we get from Hackage
data DeprecatedPackage' = DeprecatedPackage'
  { package :: PackageName
  , inFavourOf :: Vector PackageName
  }
  deriving stock (Eq, Show, Generic)

instance FromJSON DeprecatedPackage' where
  parseJSON = withObject "deprecatedPackage" $ \o -> do
    package <- o .: "deprecated-package"
    inFavourOf <- o .: "in-favour-of"
    pure DeprecatedPackage'{..}

-- DAO that we persist to the database
data DeprecatedPackage = DeprecatedPackage
  { package :: PackageName
  , inFavourOf :: Vector PackageAlternative
  }
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (ToJSON, FromJSON, NFData)
  deriving (ToField, FromField) via Aeson DeprecatedPackage

data PackageAlternative = PackageAlternative
  { namespace :: Namespace
  , package :: PackageName
  }
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (ToJSON, FromJSON, NFData)
  deriving (ToField, FromField) via Aeson PackageAlternative