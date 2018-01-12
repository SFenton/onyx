{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
module FretsOnFire where

import           Control.Applicative            ((<|>))
import           Control.Monad                  ((>=>))
import           Control.Monad.IO.Class         (MonadIO (liftIO))
import           Control.Monad.Trans.StackTrace
import           Control.Monad.Trans.Writer
import qualified Data.ByteString                as B
import           Data.Default.Class             (Default (..))
import qualified Data.HashMap.Strict            as HM
import           Data.Ini
import           Data.List                      (sortOn)
import qualified Data.Text                      as T
import qualified Data.Text.Encoding             as TE
import           Data.Text.Encoding.Error       (lenientDecode)
import           Text.Read                      (readMaybe)

data Song = Song
  { name             :: Maybe T.Text
  , artist           :: Maybe T.Text
  , album            :: Maybe T.Text
  , charter          :: Maybe T.Text -- ^ can be @frets@ or @charter@
  , year             :: Maybe Int
  , genre            :: Maybe T.Text
  , proDrums         :: Maybe Bool
  , songLength       :: Maybe Int
  , previewStartTime :: Maybe Int
  , diffBand         :: Maybe Int
  , diffGuitar       :: Maybe Int
  , diffBass         :: Maybe Int
  , diffDrums        :: Maybe Int
  , diffDrumsReal    :: Maybe Int
  , diffKeys         :: Maybe Int
  , diffKeysReal     :: Maybe Int
  , diffVocals       :: Maybe Int
  , diffVocalsHarm   :: Maybe Int
  , diffDance        :: Maybe Int
  , diffBassReal     :: Maybe Int
  , diffGuitarReal   :: Maybe Int
  , diffBassReal22   :: Maybe Int
  , diffGuitarReal22 :: Maybe Int
  , diffGuitarCoop   :: Maybe Int
  , diffRhythm       :: Maybe Int
  , diffDrumsRealPS  :: Maybe Int
  , diffKeysRealPS   :: Maybe Int
  , delay            :: Maybe Int
  , starPowerNote    :: Maybe Int -- ^ can be @star_power_note@ or @multiplier_note@
  , track            :: Maybe Int
  , sysexSlider      :: Maybe Bool
  , sysexOpenBass    :: Maybe Bool
  , video            :: Maybe FilePath
  -- TODO: video_start_time, five_lane_drums, loading_phrase
  } deriving (Eq, Ord, Show, Read)

instance Default Song where
  def = Song
    def def def def def def def def def def
    def def def def def def def def def def
    def def def def def def def def def def
    def def def

loadSong :: (MonadIO m) => FilePath -> StackTraceT m Song
loadSong fp = do
  let readIniUTF8
        = fmap (parseIni . TE.decodeUtf8With lenientDecode) . B.readFile
  ini <- inside fp $ liftIO (readIniUTF8 fp) >>= either fatal return
  -- TODO make all keys lowercase before lookup

  let str :: T.Text -> Maybe T.Text
      str k = either (const Nothing) Just $ lookupValue "song" k ini <|> lookupValue "Song" k ini
      int :: T.Text -> Maybe Int
      int = str >=> readMaybe . T.unpack
      bool :: T.Text -> Maybe Bool
      bool = str >=> readMaybe . T.unpack

      name = str "name"
      artist = str "artist"
      album = str "album"
      charter = str "charter" <|> str "frets"
      year = int "year"
      genre = str "genre"
      proDrums = bool "pro_drums"
      songLength = int "song_length"
      previewStartTime = int "preview_start_time"
      diffBand = int "diff_band"
      diffGuitar = int "diff_guitar"
      diffBass = int "diff_bass"
      diffDrums = int "diff_drums"
      diffDrumsReal = int "diff_drums_real"
      diffKeys = int "diff_keys"
      diffKeysReal = int "diff_keys_real"
      diffVocals = int "diff_vocals"
      diffVocalsHarm = int "diff_vocals_harm"
      diffDance = int "diff_dance"
      diffBassReal = int "diff_bass_real"
      diffGuitarReal = int "diff_guitar_real"
      diffBassReal22 = int "diff_bass_real_22"
      diffGuitarReal22 = int "diff_guitar_real_22"
      diffGuitarCoop = int "diff_guitar_coop"
      diffRhythm = int "diff_rhythm"
      diffDrumsRealPS = int "diff_drums_real_ps"
      diffKeysRealPS = int "diff_keys_real_ps"
      delay = int "delay"
      starPowerNote = int "star_power_note" <|> int "multiplier_note"
      track = int "track"
      sysexSlider = bool "sysex_slider"
      sysexOpenBass = bool "sysex_open_bass"
      video = fmap T.unpack $ str "video"

  return Song{..}

saveSong :: (MonadIO m) => FilePath -> Song -> m ()
saveSong fp Song{..} = writePSIni fp $
  Ini $ HM.singleton "song" $ HM.fromList $ execWriter $ do
    let str k = maybe (return ()) $ \v -> tell [(k, v)]
        shown k = str k . fmap (T.pack . show)
    str "name" name
    str "artist" artist
    str "album" album
    str "charter" charter
    str "frets" charter
    shown "year" year
    str "genre" genre
    shown "pro_drums" proDrums
    shown "song_length" songLength
    shown "preview_start_time" previewStartTime
    shown "diff_band" diffBand
    shown "diff_guitar" diffGuitar
    shown "diff_bass" diffBass
    shown "diff_drums" diffDrums
    shown "diff_drums_real" diffDrumsReal
    shown "diff_keys" diffKeys
    shown "diff_keys_real" diffKeysReal
    shown "diff_vocals" diffVocals
    shown "diff_vocals_harm" diffVocalsHarm
    shown "diff_dance" diffDance
    shown "diff_bass_real" diffBassReal
    shown "diff_guitar_real" diffGuitarReal
    shown "diff_bass_real_22" diffBassReal22
    shown "diff_guitar_real_22" diffGuitarReal22
    shown "diff_guitar_coop" diffGuitarCoop
    shown "diff_rhythm" diffRhythm
    shown "diff_drums_real_ps" diffDrumsRealPS
    shown "diff_keys_real_ps" diffKeysRealPS
    shown "delay" delay
    shown "star_power_note" starPowerNote
    shown "multiplier_note" starPowerNote
    shown "track" track
    shown "sysex_slider" sysexSlider
    shown "sysex_open_bass" sysexOpenBass
    str "video" $ fmap T.pack video

writePSIni :: (MonadIO m) => FilePath -> Ini -> m ()
writePSIni fp (Ini hmap) = let
  txt = T.intercalate "\r\n" $ map section $ sortOn fst $ HM.toList hmap
  section (title, pairs) = T.intercalate "\r\n" $
    T.concat ["[", title, "]"] : map line (sortOn fst $ HM.toList pairs)
  line (k, v) = T.concat [k, " = ", v]
  in liftIO $ B.writeFile fp $ TE.encodeUtf8 $ T.append txt "\r\n"
