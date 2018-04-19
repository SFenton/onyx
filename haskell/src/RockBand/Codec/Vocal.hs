{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
module RockBand.Codec.Vocal where

import           Control.Monad.Codec
import qualified Data.EventList.Relative.TimeBody as RTB
import           Data.Monoid                      ((<>))
import qualified Data.Text                        as T
import qualified Numeric.NonNegative.Class        as NNC
import           RockBand.Codec
import           RockBand.Common
import qualified Sound.MIDI.File.Event            as E
import qualified Sound.MIDI.File.Event.Meta       as Meta

data Pitch
  = Octave36 Key
  | Octave48 Key
  | Octave60 Key
  | Octave72 Key
  | Octave84C
  deriving (Eq, Ord, Show, Read)

pitchToKey :: Pitch -> Key
pitchToKey = \case
  Octave36 k -> k
  Octave48 k -> k
  Octave60 k -> k
  Octave72 k -> k
  Octave84C  -> C

instance Enum Pitch where
  fromEnum (Octave36 k) = fromEnum k
  fromEnum (Octave48 k) = fromEnum k + 12
  fromEnum (Octave60 k) = fromEnum k + 24
  fromEnum (Octave72 k) = fromEnum k + 36
  fromEnum Octave84C    = 48
  toEnum i = case divMod i 12 of
    (0, j) -> Octave36 $ toEnum j
    (1, j) -> Octave48 $ toEnum j
    (2, j) -> Octave60 $ toEnum j
    (3, j) -> Octave72 $ toEnum j
    (4, 0) -> Octave84C
    _      -> error $ "No vocals Pitch for: fromEnum " ++ show i

instance Bounded Pitch where
  minBound = Octave36 minBound
  maxBound = Octave84C

data PercussionType
  = Tambourine
  | Cowbell
  | Clap
  deriving (Eq, Ord, Show, Read, Enum, Bounded)

instance Command (PercussionType, Bool) where
  fromCommand (typ, b) = [T.toLower (T.pack $ show typ) <> if b then "_start" else "_end"]
  toCommand = reverseLookup ((,) <$> each <*> each) fromCommand

data VocalTrack t = VocalTrack
  { vocalMood          :: RTB.T t Mood
  , vocalLyrics        :: RTB.T t T.Text
  , vocalPerc          :: RTB.T t () -- ^ playable percussion notes
  , vocalPercSound     :: RTB.T t () -- ^ nonplayable percussion, only triggers sound sample
  , vocalPercAnimation :: RTB.T t (PercussionType, Bool)
  , vocalPhrase1       :: RTB.T t Bool -- ^ General phrase marker (RB3) or Player 1 phrases (pre-RB3)
  , vocalPhrase2       :: RTB.T t Bool -- ^ Pre-RB3, used for 2nd player phrases in Tug of War
  , vocalOverdrive     :: RTB.T t Bool
  , vocalLyricShift    :: RTB.T t ()
  , vocalRangeShift    :: RTB.T t Bool
  , vocalNotes         :: RTB.T t (Pitch, Bool)
  } deriving (Eq, Ord, Show)

instance (NNC.C t) => Monoid (VocalTrack t) where
  mempty = VocalTrack RTB.empty
    RTB.empty RTB.empty RTB.empty RTB.empty RTB.empty
    RTB.empty RTB.empty RTB.empty RTB.empty RTB.empty
  mappend
    (VocalTrack a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11)
    (VocalTrack b1 b2 b3 b4 b5 b6 b7 b8 b9 b10 b11)
    = VocalTrack
      (RTB.merge a1 b1)
      (RTB.merge a2 b2)
      (RTB.merge a3 b3)
      (RTB.merge a4 b4)
      (RTB.merge a5 b5)
      (RTB.merge a6 b6)
      (RTB.merge a7 b7)
      (RTB.merge a8 b8)
      (RTB.merge a9 b9)
      (RTB.merge a10 b10)
      (RTB.merge a11 b11)

instance TraverseTrack VocalTrack where
  traverseTrack fn (VocalTrack a b c d e f g h i j k) = VocalTrack
    <$> fn a <*> fn b <*> fn c <*> fn d <*> fn e <*> fn f
    <*> fn g <*> fn h <*> fn i <*> fn j <*> fn k

instance ParseTrack VocalTrack where
  parseTrack = do
    vocalMood   <- vocalMood   =. command
    vocalLyrics <- vocalLyrics =. let
      fp = \case
        E.MetaEvent (Meta.Lyric t) -> Just $ T.pack t
        E.MetaEvent (Meta.TextEvent t) -> case readCommand txt :: Maybe [T.Text] of
          Nothing -> Just txt -- non-command text events get defaulted to lyrics
          Just _  -> Nothing
          where txt = T.pack t
        _ -> Nothing
      fs = E.MetaEvent . Meta.Lyric . T.unpack
      in single fp fs
    vocalPerc          <- vocalPerc          =. blip 96
    vocalPercSound     <- vocalPercSound     =. blip 97
    vocalPercAnimation <- vocalPercAnimation =. command
    vocalPhrase1       <- vocalPhrase1       =. edges 105
    vocalPhrase2       <- vocalPhrase2       =. edges 106
    vocalOverdrive     <- vocalOverdrive     =. edges 116
    vocalLyricShift    <- vocalLyricShift    =. blip 1
    vocalRangeShift    <- vocalRangeShift    =. edges 0
    vocalNotes         <- (vocalNotes        =.)
      $ condenseMap $ eachKey each $ edges . (+ 36) . fromEnum
    return VocalTrack{..}