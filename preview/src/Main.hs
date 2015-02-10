module Main where

import qualified Data.EventList.Relative.TimeBody as RTB
import qualified Data.EventList.Absolute.TimeBody as ATB
import Control.Monad (forM, when, forever)
import qualified Sound.MIDI.Util as U
import qualified Data.Map as Map
import Data.Time.Clock
import Control.Exception (evaluate)
import Text.Printf

import qualified Audio
import Draw
import Midi

draw :: (ImageID -> Image) -> UTCTime -> U.Seconds -> Map.Map U.Seconds [Gem] -> IO ()
draw img start offset gems = do
  now <- getCurrentTime
  let posn = realToFrac (diffUTCTime now start) + offset
      (_,  gems') = Map.split (if posn < 0.02 then 0 else posn - 0.02) gems
      (gems'', _) = Map.split (posn + 0.1) gems'
      activeNow = concat $ Map.elems gems''
      ctx = context2d theCanvas
  drawImage (img Image_RBN_background1) 0 0 640 480 ctx
  drawImage (img Image_track_drum) 50 50 540 430 ctx
  when (Kick `elem` activeNow) $ drawImage (img Image_gem_kick) 0 100 400 25 ctx
  when (Red `elem` activeNow) $ drawImage (img Image_gem_red) 0 0 100 100 ctx
  when (Yellow `elem` activeNow) $ drawImage (img Image_gem_yellow) 100 0 100 100 ctx
  when (Blue `elem` activeNow) $ drawImage (img Image_gem_blue) 200 0 100 100 ctx
  when (Green `elem` activeNow) $ drawImage (img Image_gem_green) 300 0 100 100 ctx
  setFillStyle "white" ctx
  setFont "20px monospace" ctx
  let dposn = realToFrac posn :: Double
      mins = floor $ dposn / 60 :: Int
      secs = dposn - fromIntegral mins * 60 :: Double
      timestamp = printf "%02d:%06.3f" mins secs :: String
  fillText timestamp 10 150 ctx

main :: IO ()
main = do
  howlSong <- Audio.load ["another-day/song-countin.ogg", "another-day/song-countin.mp3"]
  howlDrums <- Audio.load ["another-day/drums.ogg", "another-day/drums.mp3"]
  putStrLn "Loaded Howl."
  mid <- loadMidi "another-day/notes.mid"
  putStrLn "Loaded MIDI."
  case U.decodeFile mid of
    Right _ -> undefined
    Left trks -> let
      tmap = U.makeTempoMap $ head trks
      trk = foldr RTB.merge RTB.empty $ filter (\t -> U.trackName t == Just "PART DRUMS") trks
      gemTrack :: RTB.T U.Seconds Gem
      gemTrack = U.applyTempoTrack tmap $ RTB.mapMaybe isGem trk
      gemMap :: Map.Map U.Seconds [Gem]
      gemMap = Map.fromAscList $ ATB.toPairList $ RTB.toAbsoluteEventList 0 $
        RTB.collectCoincident gemTrack
      in do
        _ <- evaluate gemMap
        Audio.play howlSong
        Audio.play howlDrums
        start <- getCurrentTime
        imgs <- fmap Map.fromList $ forM [minBound .. maxBound] $ \iid -> do
          img <- loadImage $ "rbprev/" ++ drop 6 (show iid) ++ ".png"
          return (iid, img)
        let imgLookup iid = case Map.lookup iid imgs of
              Just img -> img
              Nothing  -> error $ "couldn't load image " ++ show iid
        forever $ do
          draw imgLookup start 0 gemMap
          requestAnimationFrame

data ImageID
  = Image_RBN_background1
  | Image_beat_marker
  | Image_gem_blue
  | Image_gem_cym_blue
  | Image_gem_cym_green
  | Image_gem_cym_style
  | Image_gem_cym_yellow
  | Image_gem_green
  | Image_gem_hopo_blue
  | Image_gem_hopo_green
  | Image_gem_hopo_orange
  | Image_gem_hopo_red
  | Image_gem_hopo_style
  | Image_gem_hopo_yellow
  | Image_gem_kick
  | Image_gem_kick_style
  | Image_gem_orange
  | Image_gem_red
  | Image_gem_style
  | Image_gem_yellow
  | Image_half_beat_marker
  | Image_kick_flash_1
  | Image_kick_flash_2
  | Image_kick_flash_3
  | Image_kick_flash_4
  | Image_kick_flash_5
  | Image_kick_flash_6
  | Image_kick_flash_7
  | Image_measure
  | Image_smash_1
  | Image_smash_10
  | Image_smash_2
  | Image_smash_3
  | Image_smash_4
  | Image_smash_5
  | Image_smash_6
  | Image_smash_7
  | Image_smash_8
  | Image_smash_9
  | Image_smash_flare_blue
  | Image_smash_flare_green
  | Image_smash_flare_orange
  | Image_smash_flare_red
  | Image_smash_flare_style
  | Image_smash_flare_yellow
  | Image_sustain_blue
  | Image_sustain_blue_hi
  | Image_sustain_green
  | Image_sustain_green_hi
  | Image_sustain_orange
  | Image_sustain_orange_hi
  | Image_sustain_red
  | Image_sustain_red_hi
  | Image_sustain_style
  | Image_sustain_style_hi
  | Image_sustain_yellow
  | Image_sustain_yellow_hi
  | Image_track_drum
  | Image_track_guitar
  deriving (Eq, Ord, Show, Read, Enum, Bounded)
