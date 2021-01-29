{- |
Ported from FsbDecrypt.java by Quidrex
https://www.fretsonfire.org/forums/viewtopic.php?t=60499
-}
module GuitarHero5.Audio where

import           Control.Monad       (guard)
import           Crypto.Cipher.AES
import           Crypto.Cipher.Types
import           Crypto.Error
import qualified Data.ByteString     as B

keys :: [B.ByteString]
keys = map B.pack
  [ [0x52, 0xaa, 0xa1, 0x32, 0x01, 0x75, 0x9c, 0x0f, 0x5d, 0x5e, 0x7d, 0x7c, 0x23, 0xc8, 0x1d, 0x3c]
  , [0xb7, 0x5c, 0xb8, 0x9c, 0xf6, 0xd5, 0x49, 0xb8, 0x98, 0x1d, 0xf4, 0xb6, 0xf7, 0xb8, 0xc6, 0x65]
  , [0x66, 0x48, 0x87, 0x0d, 0x9a, 0x5c, 0x02, 0x92, 0x98, 0x0a, 0xdc, 0xfb, 0xa9, 0x32, 0xae, 0x37]
  , [0x55, 0xe3, 0x2b, 0x01, 0x56, 0x4e, 0xe0, 0xda, 0xbf, 0x0d, 0x16, 0x94, 0x72, 0x13, 0x26, 0x51]
  , [0xd5, 0xae, 0x03, 0x0f, 0xda, 0x7d, 0x3e, 0xee, 0x8c, 0x71, 0x12, 0x03, 0xbc, 0x99, 0xea, 0xdb]
  , [0x16, 0xb1, 0x71, 0xce, 0x24, 0x36, 0xac, 0x6e, 0xad, 0xee, 0x18, 0x29, 0x09, 0x06, 0x58, 0x61]
  , [0x2a, 0x28, 0x65, 0x4a, 0xfe, 0xfd, 0xb6, 0x8f, 0x31, 0xb6, 0x76, 0x9b, 0xcc, 0x0a, 0xf6, 0x2f]
  , [0xd3, 0x2f, 0x95, 0x9d, 0x7c, 0xb3, 0x67, 0x25, 0xf4, 0x2e, 0x73, 0xa5, 0xd2, 0x90, 0x8b, 0x45]
  , [0xad, 0x1d, 0x56, 0x58, 0xfe, 0x67, 0x70, 0x57, 0xc5, 0x90, 0x18, 0x06, 0x25, 0x09, 0xd6, 0x05]
  , [0xd4, 0xfd, 0x8b, 0x1b, 0x79, 0x53, 0xe6, 0x1a, 0xb8, 0x63, 0x25, 0x65, 0xea, 0x32, 0xfe, 0x56]
  , [0x17, 0x67, 0x02, 0xee, 0xf5, 0x6e, 0xf8, 0xb9, 0xfa, 0xfd, 0xe3, 0xa1, 0x49, 0xb8, 0xf4, 0x51]
  , [0x02, 0x51, 0xa8, 0xe1, 0x77, 0x23, 0x6b, 0xdd, 0x95, 0x88, 0x20, 0x5a, 0xd2, 0x49, 0x97, 0x98]
  , [0xcd, 0xab, 0xf1, 0x72, 0x25, 0x96, 0x2e, 0x42, 0xec, 0x8a, 0x8f, 0x3c, 0x8f, 0x77, 0x6a, 0xb0]
  , [0x4e, 0x23, 0x00, 0xd0, 0xd9, 0x2c, 0x71, 0x95, 0x2b, 0xf7, 0x17, 0xea, 0x10, 0x4f, 0xce, 0x11]
  , [0x4c, 0x5d, 0xcf, 0xd8, 0xf6, 0x0b, 0x06, 0xf5, 0x87, 0x56, 0x7a, 0xa3, 0x5e, 0xab, 0xd8, 0xdf]
  , [0x44, 0x95, 0xb4, 0xd8, 0xd2, 0xc1, 0x81, 0xff, 0x3a, 0x8f, 0x03, 0x1f, 0x03, 0xf2, 0xbb, 0x7f]
  , [0xeb, 0xcc, 0x7d, 0xe4, 0xf5, 0xc3, 0xaf, 0xaa, 0x85, 0x7c, 0x67, 0xdb, 0x15, 0xdf, 0x14, 0xa7]
  , [0x84, 0x52, 0x71, 0xcd, 0xff, 0x12, 0x31, 0x61, 0xde, 0x64, 0x23, 0x01, 0x03, 0x2f, 0xc4, 0xdf]
  , [0xfe, 0xf3, 0x2e, 0x40, 0x06, 0xd7, 0x92, 0x24, 0xda, 0x65, 0x74, 0xd3, 0xdb, 0xef, 0x67, 0xa6]
  , [0x99, 0xf1, 0xd6, 0xa9, 0x4c, 0x80, 0x66, 0xdf, 0xf7, 0x3d, 0xc2, 0xd3, 0x6a, 0x1b, 0x00, 0xf5]
  , [0x7e, 0x61, 0x97, 0x6a, 0xb5, 0x89, 0xc2, 0x31, 0x4d, 0xab, 0x77, 0x0e, 0x3f, 0xf1, 0xbb, 0xb5]
  , [0x27, 0x94, 0x2e, 0xf1, 0xb8, 0xab, 0xb5, 0xda, 0x57, 0x58, 0x03, 0x74, 0x19, 0x9c, 0x9b, 0x90]
  , [0xdc, 0x13, 0xb0, 0xda, 0x49, 0xc3, 0x44, 0xfb, 0xec, 0x82, 0x64, 0x56, 0x45, 0xc6, 0xb6, 0xd2]
  , [0xe2, 0x68, 0x01, 0x47, 0xf9, 0x51, 0x66, 0x80, 0x7a, 0xe7, 0x3e, 0x43, 0xb8, 0x34, 0x84, 0xa5]
  , [0xdb, 0x75, 0x10, 0x80, 0x4e, 0x20, 0xaf, 0x0e, 0x04, 0xa3, 0xcd, 0x15, 0xed, 0x2e, 0x5a, 0xb8]
  , [0xd3, 0x72, 0x39, 0x72, 0x75, 0x86, 0xe4, 0x63, 0xdf, 0xe2, 0x70, 0x35, 0xb0, 0x52, 0x17, 0x55]
  , [0x4c, 0xce, 0x2f, 0xc6, 0xae, 0x40, 0x1c, 0x2f, 0x40, 0xb9, 0xda, 0x78, 0x02, 0x77, 0xd2, 0x5d]
  , [0x7b, 0xff, 0x02, 0xda, 0xa8, 0x43, 0xe7, 0x43, 0x86, 0x39, 0xa9, 0x0f, 0x1c, 0x81, 0xd0, 0x7a]
  , [0x7c, 0xe5, 0x85, 0x9b, 0xaf, 0x8e, 0xc6, 0x83, 0x7d, 0x4a, 0x53, 0xb1, 0x2c, 0xd5, 0x1e, 0x65]
  , [0xef, 0x7f, 0xbb, 0xb8, 0x75, 0xfc, 0xdc, 0xc2, 0x52, 0x61, 0xd4, 0xe9, 0x9a, 0x86, 0xd0, 0x58]
  , [0x52, 0x25, 0x59, 0xfb, 0x6f, 0x62, 0x54, 0xdf, 0x16, 0x7b, 0x0a, 0x94, 0xf0, 0x61, 0x26, 0x7c]
  , [0xd8, 0x69, 0xd0, 0x33, 0x8b, 0x0a, 0xa5, 0xf8, 0xd5, 0xdc, 0xda, 0x4e, 0x14, 0xf2, 0x6a, 0xfe]
  , [0x0f, 0x7f, 0x33, 0xc8, 0xd5, 0x1d, 0xe6, 0xe6, 0x16, 0x6e, 0x61, 0xea, 0xb0, 0xf4, 0x14, 0xea]
  , [0x1b, 0x57, 0x3f, 0x92, 0xbc, 0xf3, 0x6c, 0xf3, 0xc0, 0x10, 0xae, 0x5f, 0x8b, 0xf6, 0xe5, 0x5e]
  , [0x79, 0x19, 0xca, 0xf6, 0x07, 0x5e, 0xd4, 0xe2, 0x15, 0x45, 0x60, 0x0d, 0x2f, 0xb8, 0x05, 0x7e]
  , [0x31, 0x8e, 0x95, 0x4f, 0x77, 0xbe, 0xb8, 0xa9, 0xd5, 0xb1, 0x10, 0x80, 0xb3, 0x24, 0xdd, 0x4f]
  , [0x91, 0x9e, 0x4d, 0x54, 0x9d, 0xd5, 0x6c, 0x9c, 0x3e, 0x26, 0x7a, 0x33, 0xd3, 0x16, 0xe8, 0x87]
  , [0x4d, 0x43, 0xa0, 0xff, 0xf6, 0xd4, 0x13, 0x7d, 0xe9, 0xfd, 0x6d, 0xd5, 0x9d, 0x21, 0xd3, 0x98]
  , [0x90, 0xc5, 0x14, 0x65, 0xdb, 0xa7, 0xb3, 0x68, 0xaa, 0xbc, 0x5a, 0x46, 0xee, 0xc9, 0x08, 0x36]
  , [0x66, 0xb8, 0x25, 0xf7, 0x3e, 0xd3, 0x5b, 0x55, 0xfc, 0x3a, 0x5e, 0xc5, 0xe9, 0x9a, 0x76, 0x2a]
  , [0x03, 0x94, 0x20, 0x25, 0x85, 0xb6, 0x18, 0xc8, 0x30, 0xe4, 0x38, 0x2d, 0x95, 0x9e, 0xec, 0x2a]
  , [0xdf, 0x23, 0xa6, 0xbb, 0x25, 0x8b, 0x86, 0xdc, 0x8c, 0xe0, 0xd8, 0xc1, 0xc9, 0xb3, 0xcd, 0xe5]
  , [0xd1, 0xbe, 0x7b, 0x1c, 0x2f, 0x3d, 0xdd, 0x35, 0xab, 0xcf, 0x9f, 0xe8, 0x56, 0x8e, 0x8b, 0x34]
  , [0x5f, 0x8b, 0x3f, 0x45, 0x02, 0xdd, 0xa4, 0x2a, 0xe6, 0x9f, 0x89, 0x0f, 0xbf, 0x5a, 0xbb, 0xad]
  , [0x98, 0x76, 0x9f, 0x42, 0x71, 0xee, 0xff, 0xf6, 0xc1, 0x0e, 0x78, 0x9a, 0xc5, 0x74, 0xbc, 0x03]
  , [0x94, 0xa8, 0xca, 0x5a, 0xb1, 0x91, 0xd6, 0xec, 0x11, 0x2e, 0x83, 0x36, 0xd3, 0xe8, 0x25, 0x70]
  , [0x4e, 0x90, 0x4b, 0xfe, 0x1c, 0x49, 0xc5, 0x32, 0x7b, 0x95, 0x53, 0x2b, 0x0d, 0x63, 0x67, 0xa0]
  , [0x62, 0x0f, 0xc1, 0x1c, 0x07, 0xc6, 0x2a, 0x2a, 0x3e, 0xe2, 0x6a, 0x08, 0xc6, 0xf1, 0x2e, 0xdf]
  , [0x3c, 0x76, 0x0e, 0x4a, 0x0b, 0xe7, 0x93, 0x79, 0xef, 0xf5, 0x0e, 0xae, 0x45, 0x1e, 0x10, 0x05]
  , [0x60, 0x2b, 0xdf, 0xd2, 0x5a, 0xd8, 0xf9, 0x03, 0x78, 0x0f, 0x63, 0xfe, 0xec, 0xae, 0x98, 0x7b]
  , [0xb2, 0x16, 0xc7, 0x9d, 0xc4, 0x34, 0x82, 0x11, 0xbe, 0xa9, 0x53, 0xc8, 0x07, 0x40, 0xdc, 0x27]
  , [0x1f, 0x1c, 0x78, 0x45, 0x91, 0x88, 0xf7, 0x8a, 0x3d, 0x2a, 0x29, 0x3d, 0x19, 0xf3, 0x66, 0xb0]
  , [0x2a, 0xba, 0xdf, 0x5f, 0xe5, 0x0a, 0xbe, 0xc5, 0xaa, 0x75, 0x15, 0xb8, 0x12, 0xf7, 0xee, 0xfd]
  , [0x53, 0xe8, 0x58, 0xb9, 0x29, 0x1e, 0xdf, 0x01, 0xdc, 0x45, 0x79, 0x3c, 0x80, 0xf8, 0x62, 0x7c]
  , [0x72, 0xca, 0x86, 0x31, 0x55, 0x97, 0x14, 0xbc, 0xdb, 0x9f, 0xb9, 0x4e, 0x61, 0xf7, 0xd3, 0x2c]
  , [0x66, 0x3b, 0x7d, 0xac, 0x09, 0xba, 0x0f, 0x49, 0x73, 0x05, 0x04, 0x51, 0x6f, 0x6a, 0xaf, 0x51]
  , [0x88, 0xd6, 0xc3, 0xe7, 0x42, 0x46, 0xfe, 0x6b, 0x85, 0x88, 0x63, 0x7e, 0x85, 0x3b, 0xc9, 0xb8]
  , [0x26, 0x7a, 0x43, 0x39, 0xed, 0xaa, 0xb6, 0xfb, 0x03, 0xdd, 0x2a, 0x47, 0x74, 0xd6, 0x06, 0x32]
  , [0x20, 0x94, 0x04, 0xae, 0xe1, 0x7e, 0xb4, 0x1d, 0x7c, 0xce, 0xea, 0x85, 0x2f, 0x07, 0x88, 0x31]
  , [0x08, 0x63, 0x47, 0x94, 0x58, 0xcc, 0xe3, 0x74, 0x7e, 0x4b, 0xb3, 0x25, 0xb8, 0x25, 0x34, 0xa6]
  , [0x3d, 0x62, 0x5c, 0xfc, 0xd5, 0x2c, 0xad, 0x46, 0x38, 0xdf, 0x76, 0x1e, 0x84, 0x08, 0x56, 0x27]
  , [0xaf, 0x8e, 0x2d, 0xbb, 0x5c, 0xb9, 0xba, 0x47, 0x6f, 0xaa, 0x72, 0xed, 0x8a, 0x2b, 0xe8, 0x88]
  , [0x34, 0xcb, 0xb0, 0x59, 0x6b, 0xb1, 0xd9, 0xdc, 0x1e, 0x1b, 0xa1, 0xb9, 0xbc, 0xd1, 0x83, 0xce]
  , [0x6c, 0xc6, 0x80, 0xbc, 0x8f, 0x70, 0x6d, 0x67, 0xc1, 0xe3, 0x1b, 0x56, 0x01, 0xa4, 0x89, 0x90]
  , [0xef, 0x24, 0x71, 0xbd, 0x4d, 0x58, 0x15, 0x55, 0x1e, 0x2d, 0x38, 0x02, 0x15, 0x5b, 0x77, 0xb2]
  , [0x66, 0x51, 0xef, 0x6c, 0x29, 0x9b, 0x93, 0x8f, 0xe0, 0xac, 0x11, 0xfb, 0x7a, 0xa3, 0xc7, 0xc2]
  , [0x3b, 0x55, 0x86, 0xd3, 0x00, 0xd9, 0x50, 0x64, 0x43, 0xc7, 0xbe, 0x68, 0x0f, 0x9e, 0xd7, 0xae]
  , [0xc9, 0x99, 0x15, 0x97, 0xd3, 0xa3, 0x46, 0xf4, 0xee, 0xc7, 0xc4, 0x37, 0x14, 0xe7, 0xc9, 0x25]
  , [0x33, 0xe1, 0xf4, 0xce, 0xdc, 0x4c, 0xc9, 0x9f, 0xb0, 0x7d, 0x5a, 0x47, 0x29, 0x30, 0x90, 0xf4]
  , [0x60, 0x18, 0x5e, 0x79, 0x10, 0x8f, 0x27, 0x90, 0x10, 0xea, 0xdf, 0x45, 0xa3, 0xa1, 0x8e, 0x89]
  , [0xe3, 0x54, 0x8b, 0xa3, 0x18, 0xf6, 0x00, 0x86, 0xba, 0xac, 0x46, 0x5a, 0x99, 0x34, 0xc4, 0x54]
  , [0xd1, 0xb0, 0x43, 0xb3, 0xd4, 0x28, 0x7e, 0x28, 0xdb, 0xd4, 0x17, 0x82, 0x7d, 0x3f, 0x24, 0x45]
  , [0xca, 0x14, 0x87, 0xfd, 0x11, 0xec, 0xae, 0xd9, 0x33, 0x02, 0x96, 0x61, 0xd1, 0xe5, 0x44, 0xc3]
  , [0x79, 0x9a, 0x5a, 0xb2, 0xa1, 0x38, 0x6a, 0xac, 0x69, 0x3e, 0xbc, 0x86, 0x7b, 0xe1, 0xf0, 0xb8]
  , [0xf5, 0xd3, 0x3e, 0x01, 0xcd, 0xce, 0x13, 0x05, 0x8a, 0xc2, 0x99, 0xdc, 0xca, 0x9b, 0x7d, 0xef]
  , [0xd4, 0x2d, 0xdd, 0xe3, 0x2c, 0x9d, 0xba, 0xbe, 0xbf, 0xca, 0x15, 0xa5, 0x1d, 0x94, 0x91, 0x03]
  , [0xdf, 0xbf, 0x74, 0x27, 0x86, 0xc7, 0x06, 0x25, 0x0a, 0xba, 0x7d, 0xf7, 0x1e, 0xd6, 0x41, 0x26]
  , [0xfc, 0x88, 0x53, 0xf3, 0x40, 0xb1, 0xfc, 0x34, 0x11, 0xdd, 0xdb, 0x4e, 0xb7, 0x53, 0xf0, 0x82]
  , [0x0f, 0xcd, 0x21, 0x05, 0xf6, 0x76, 0xdf, 0x2e, 0xb2, 0xf9, 0xf2, 0x21, 0x19, 0xb6, 0x08, 0x67]
  , [0x50, 0xfb, 0x12, 0x8f, 0x12, 0xd6, 0xaa, 0xa8, 0x75, 0x43, 0x01, 0xef, 0xd3, 0xab, 0x80, 0x94]
  , [0x9a, 0xee, 0x72, 0xa8, 0x71, 0xc8, 0xa5, 0xf2, 0xcc, 0x12, 0x59, 0x0b, 0x0e, 0xfe, 0x2e, 0xf4]
  , [0x53, 0x2a, 0x35, 0xd6, 0x9c, 0x74, 0x4b, 0x26, 0x0f, 0x6f, 0xbc, 0xc1, 0x7d, 0x66, 0xf6, 0x83]
  , [0x35, 0x67, 0x04, 0xda, 0xf2, 0xef, 0x07, 0x9d, 0x6b, 0x9b, 0xf4, 0x40, 0x8e, 0x6f, 0x51, 0x0d]
  , [0x0c, 0x6d, 0x31, 0x7f, 0x01, 0xd2, 0x45, 0x95, 0x30, 0xad, 0xf6, 0x78, 0x8e, 0xa0, 0xaa, 0x2b]
  , [0x03, 0xb2, 0x79, 0x10, 0x04, 0x24, 0xeb, 0xe5, 0x58, 0x3e, 0xa6, 0x30, 0xda, 0x1b, 0x9e, 0x1c]
  , [0x8b, 0x5d, 0x28, 0x53, 0x9f, 0x63, 0xee, 0x78, 0x9f, 0x01, 0x86, 0x4c, 0xe3, 0xb3, 0x99, 0x8c]
  , [0xfa, 0xf5, 0x14, 0x58, 0xc5, 0x43, 0x6b, 0x98, 0x32, 0x44, 0x5b, 0x7b, 0x1f, 0xcb, 0xe5, 0xb4]
  , [0x9c, 0xc9, 0x80, 0x30, 0x7e, 0x2a, 0xce, 0x25, 0xaf, 0xa7, 0x28, 0x02, 0x85, 0xe6, 0x88, 0xd8]
  , [0x07, 0x5d, 0x7c, 0xc0, 0xbd, 0x2a, 0x64, 0xfa, 0xf8, 0x1b, 0x1a, 0xe5, 0x50, 0xb7, 0x83, 0xc1]
  , [0xaf, 0x1a, 0x21, 0xe3, 0xfd, 0x7f, 0x4c, 0x39, 0xc1, 0x86, 0x55, 0xb0, 0x14, 0x0c, 0xbc, 0x2c]
  , [0x50, 0x0a, 0xd1, 0xa6, 0x48, 0x49, 0x83, 0x26, 0x94, 0x7e, 0x5a, 0x2d, 0x17, 0xf4, 0xb3, 0x05]
  , [0xe6, 0x31, 0x11, 0xf6, 0x7d, 0xe9, 0x64, 0x3e, 0xcd, 0x30, 0xc9, 0xf3, 0xcc, 0x58, 0x62, 0xfe]
  , [0x12, 0xbf, 0xda, 0x34, 0xbb, 0x16, 0x08, 0x6f, 0x73, 0xb1, 0x64, 0xf0, 0x82, 0xa3, 0x46, 0xe6]
  , [0x92, 0xe7, 0xc0, 0x46, 0x16, 0x4f, 0xbc, 0x4e, 0xb9, 0x8e, 0x70, 0xad, 0xd5, 0x6c, 0xe6, 0xa6]
  , [0x9a, 0x97, 0xf3, 0xc2, 0x2e, 0x4e, 0x0b, 0x01, 0xfd, 0x75, 0xdb, 0x89, 0x18, 0xad, 0xb5, 0xda]
  , [0x33, 0x2b, 0xc7, 0xf5, 0x5a, 0x64, 0xb2, 0x37, 0xd9, 0x15, 0xd2, 0xd9, 0x01, 0x58, 0xf6, 0x82]
  , [0xe4, 0x10, 0xc9, 0x5e, 0x5d, 0x79, 0xbf, 0xf5, 0xfe, 0x94, 0x47, 0xc9, 0x8e, 0x2e, 0x7d, 0x0f]
  , [0xbe, 0xd2, 0x7b, 0x06, 0xf1, 0xf2, 0x0b, 0xe8, 0x63, 0x7c, 0xcd, 0x17, 0x94, 0x36, 0xdb, 0x53]
  , [0xfd, 0x59, 0xde, 0xa3, 0x57, 0xd5, 0x65, 0xc5, 0xca, 0x9e, 0x49, 0xcc, 0xe2, 0x10, 0xa4, 0xd8]
  , [0x92, 0xf0, 0x8c, 0xb6, 0x90, 0x0a, 0xc1, 0x08, 0x1e, 0xdd, 0x3d, 0xfe, 0xc4, 0x10, 0xb8, 0xea]
  , [0x0a, 0xc2, 0xc0, 0xa8, 0xdb, 0xee, 0x2c, 0xcc, 0x1a, 0x58, 0x64, 0x64, 0x3f, 0x54, 0xcc, 0x14]
  , [0x8a, 0x80, 0x15, 0xcd, 0x8e, 0xf5, 0x6f, 0x84, 0xed, 0x06, 0xdf, 0xc0, 0xfe, 0xe7, 0x17, 0x52]
  , [0x68, 0x3b, 0x78, 0xcd, 0xfb, 0xb0, 0x21, 0xb0, 0x66, 0x3f, 0xfb, 0x5d, 0xef, 0xa1, 0x19, 0xc8]
  , [0xda, 0x19, 0xf4, 0xee, 0x21, 0xde, 0x15, 0x09, 0xb8, 0x2f, 0xb6, 0x13, 0x08, 0xb8, 0x6c, 0x5b]
  , [0x5b, 0x67, 0xb7, 0x2f, 0xd5, 0x5f, 0x74, 0x85, 0x63, 0x58, 0xdf, 0x7b, 0x90, 0x3b, 0xf9, 0x90]
  , [0x5f, 0xd3, 0x63, 0x64, 0xbc, 0xf4, 0x61, 0x5d, 0x80, 0xe9, 0x05, 0x83, 0x4a, 0x5e, 0xa3, 0xae]
  , [0x40, 0x19, 0x9b, 0xb7, 0xf9, 0xc1, 0x1e, 0x38, 0x9f, 0x62, 0x5c, 0x34, 0xed, 0x62, 0x80, 0x0f]
  , [0x0a, 0x7c, 0xc1, 0xfd, 0x08, 0xcf, 0x4b, 0x3e, 0xca, 0x78, 0xb4, 0x77, 0xe7, 0xba, 0x68, 0x02]
  , [0xd4, 0xc3, 0x03, 0xc5, 0x8e, 0xc4, 0x7d, 0x70, 0xd1, 0xa6, 0x60, 0xb8, 0x25, 0x1f, 0xcf, 0xe6]
  , [0x26, 0xb1, 0x14, 0xdf, 0x0b, 0xda, 0x7c, 0x42, 0x20, 0x4a, 0x96, 0x9a, 0x11, 0x87, 0xfc, 0x42]
  , [0x36, 0x1e, 0xa5, 0xd6, 0x82, 0x25, 0xdb, 0x71, 0xc2, 0xa9, 0x88, 0x17, 0xf5, 0xce, 0xd8, 0xf4]
  , [0x50, 0xf3, 0x4c, 0x9a, 0xd2, 0x9f, 0xd3, 0x8e, 0x77, 0x19, 0x2e, 0xa1, 0xee, 0xf8, 0x75, 0x31]
  , [0x89, 0x8d, 0x56, 0x79, 0x97, 0xfa, 0x0e, 0xd4, 0xe0, 0x71, 0x36, 0xb2, 0xb2, 0x81, 0x24, 0xc1]
  , [0x1a, 0xab, 0x79, 0x73, 0x6e, 0xe5, 0xf4, 0xc6, 0x7d, 0xf4, 0x31, 0x57, 0x6b, 0x22, 0xe4, 0xce]
  , [0x93, 0x7f, 0x01, 0x38, 0xd7, 0x48, 0x56, 0x94, 0x69, 0x86, 0x28, 0xd7, 0x5d, 0x6d, 0x44, 0x99]
  , [0xee, 0x5e, 0x3d, 0x04, 0x70, 0x50, 0xa3, 0xfa, 0x64, 0x9b, 0x82, 0xa4, 0x1f, 0xe3, 0x5e, 0x11]
  , [0x93, 0x7d, 0x16, 0x68, 0x00, 0x59, 0xd1, 0x7f, 0x2d, 0x69, 0x40, 0x64, 0x95, 0x46, 0x8c, 0xe2]
  , [0x2c, 0xfa, 0x80, 0x23, 0xd0, 0x9c, 0xf8, 0xde, 0xd7, 0x1b, 0xc1, 0x66, 0x64, 0xe6, 0xe4, 0xfe]
  , [0xd9, 0x30, 0x76, 0xfc, 0x25, 0xf7, 0x9d, 0x83, 0x1b, 0xc0, 0xdb, 0x60, 0xab, 0x41, 0x84, 0x27]
  , [0x6f, 0x0f, 0x68, 0x50, 0xf7, 0xa4, 0xc7, 0xb1, 0xc5, 0xbb, 0x59, 0x98, 0x5e, 0xcf, 0x7f, 0x0c]
  , [0x75, 0x26, 0xb4, 0xe0, 0xc6, 0xd2, 0x6b, 0x2e, 0xb7, 0xc3, 0xba, 0x72, 0x5c, 0x2f, 0x2a, 0x4d]
  , [0x14, 0x96, 0x11, 0xf2, 0xcc, 0x8e, 0x5f, 0xdd, 0xa5, 0x70, 0xf4, 0x0a, 0x2f, 0x5e, 0x6f, 0x32]
  , [0x0a, 0x3b, 0x33, 0x0b, 0x99, 0xd0, 0x47, 0x31, 0xe1, 0x19, 0xc5, 0x94, 0x06, 0x97, 0x5f, 0xd1]
  , [0x1d, 0x74, 0x30, 0xf1, 0x8f, 0xa9, 0x85, 0x32, 0xb8, 0x2b, 0x84, 0xb2, 0x5a, 0x4e, 0xf7, 0x22]
  , [0xf6, 0x36, 0xc4, 0xdf, 0x6d, 0xa4, 0x45, 0xc1, 0x5f, 0xa0, 0xd1, 0x35, 0xbe, 0xba, 0x2b, 0xc9]
  , [0xb5, 0x30, 0x94, 0x84, 0xa6, 0xb4, 0xdd, 0xa5, 0x33, 0x1a, 0xf5, 0xde, 0x5c, 0x78, 0xb1, 0xb9]
  , [0xfe, 0x28, 0xa5, 0x26, 0xf8, 0xd8, 0x4d, 0x2a, 0x49, 0x1d, 0x52, 0xfd, 0x8e, 0xd4, 0x56, 0x17]
  , [0xfb, 0x81, 0x73, 0x10, 0x99, 0x89, 0xdb, 0x2b, 0xde, 0x12, 0xa1, 0xe0, 0x20, 0x08, 0x4b, 0x5d]
  , [0xa5, 0x8e, 0x8e, 0x10, 0x21, 0x1d, 0x3c, 0x68, 0x38, 0xab, 0x7a, 0x01, 0x48, 0x08, 0xcb, 0xf0]
  , [0xbe, 0x1b, 0xa9, 0x30, 0x41, 0x05, 0xb6, 0x0a, 0x42, 0xe9, 0xfc, 0xfb, 0xad, 0x4d, 0x79, 0x88]
  , [0xea, 0x2c, 0x4f, 0x33, 0x48, 0xdb, 0x52, 0x92, 0x9a, 0x87, 0xe3, 0x8f, 0x20, 0x12, 0x3a, 0xc4]
  , [0xe7, 0x89, 0x77, 0x08, 0x0b, 0x5c, 0xee, 0xe8, 0x69, 0x27, 0x37, 0x58, 0x81, 0xc0, 0x8f, 0x98]
  , [0x6c, 0x26, 0xa6, 0xe2, 0x5f, 0x59, 0xf0, 0x82, 0x95, 0xd3, 0x66, 0xa8, 0xc6, 0x22, 0xfb, 0xa8]
  , [0x89, 0x4c, 0x97, 0x40, 0x36, 0x83, 0x7f, 0xb0, 0xb2, 0x04, 0x18, 0x77, 0x17, 0x21, 0x2a, 0x7e]
  , [0x07, 0x03, 0x37, 0x18, 0x64, 0xb5, 0xfb, 0x30, 0x7a, 0xb2, 0x3f, 0x55, 0x96, 0x93, 0x5a, 0x2c]
  , [0x83, 0xd1, 0xd2, 0x59, 0xe5, 0x0f, 0x4c, 0xcb, 0x9b, 0xad, 0xbc, 0xa5, 0xbe, 0x23, 0x68, 0x76]
  , [0x4e, 0x27, 0xf8, 0xa0, 0x14, 0x70, 0x3a, 0x9e, 0x51, 0xd8, 0x35, 0x17, 0x0e, 0xca, 0xb6, 0x43]
  , [0x13, 0x67, 0x40, 0x5f, 0xcd, 0xd9, 0x1c, 0x55, 0x4e, 0xdb, 0x24, 0xa1, 0x28, 0x83, 0x59, 0x51]
  , [0x2d, 0xb2, 0x91, 0x40, 0xc5, 0x2b, 0xf1, 0x77, 0xd0, 0xcd, 0xba, 0xc6, 0x8e, 0x53, 0xbd, 0x7b]
  , [0x59, 0xa6, 0x5c, 0xf3, 0x0f, 0xa0, 0xf3, 0x32, 0x92, 0xf1, 0xee, 0xbd, 0x5b, 0xf9, 0x06, 0x32]
  , [0x8e, 0x28, 0x34, 0x93, 0x79, 0xcc, 0xc1, 0x1b, 0x2e, 0xee, 0x15, 0x43, 0xc4, 0x6f, 0xf6, 0x39]
  , [0x1f, 0x2a, 0xbe, 0x72, 0x35, 0x55, 0xc8, 0x5f, 0x5b, 0xa3, 0x2d, 0xaf, 0x47, 0xae, 0x3c, 0x59]
  , [0xaf, 0xce, 0x3c, 0x8e, 0x51, 0x7d, 0xf0, 0x3a, 0xea, 0xaa, 0xfd, 0x0d, 0x81, 0x86, 0x00, 0x9b]
  , [0x65, 0xae, 0x29, 0x6b, 0x6d, 0xbe, 0x8f, 0xd5, 0x95, 0x68, 0x4a, 0x14, 0x4a, 0xb2, 0x15, 0x25]
  , [0x39, 0xd6, 0xe2, 0xc4, 0x9a, 0x9a, 0x91, 0xa0, 0x6f, 0x0f, 0xc4, 0x29, 0xe2, 0x0b, 0x62, 0x27]
  , [0x15, 0x84, 0x54, 0x98, 0x2f, 0x34, 0x87, 0x49, 0xa5, 0x8f, 0xff, 0xd1, 0xdc, 0xc9, 0x5a, 0xdb]
  , [0xdd, 0xed, 0xca, 0x47, 0x3f, 0x1b, 0x26, 0x02, 0xa9, 0x29, 0xdc, 0xf0, 0x9c, 0x8f, 0xa2, 0x3e]
  , [0xfc, 0x2f, 0x5a, 0xb0, 0x93, 0xa2, 0x14, 0xbe, 0x7e, 0x32, 0x3b, 0xd5, 0x38, 0x43, 0x34, 0x7d]
  , [0x1b, 0x53, 0x73, 0xc7, 0xc1, 0x8e, 0xcb, 0x87, 0xc8, 0xe3, 0xae, 0xb9, 0x73, 0x6a, 0xcd, 0x09]
  , [0xfa, 0x32, 0xc4, 0x5c, 0x3e, 0x73, 0x09, 0xf2, 0x0a, 0xb3, 0xde, 0xa0, 0x01, 0xf6, 0x26, 0xae]
  , [0x26, 0x82, 0x4c, 0x75, 0xc6, 0xc7, 0x46, 0x7c, 0x47, 0xfd, 0xcc, 0xef, 0x8f, 0xc2, 0xe9, 0x89]
  , [0x12, 0x9a, 0xe0, 0xdd, 0x18, 0x08, 0x55, 0xde, 0x16, 0x60, 0x1a, 0xe5, 0xa6, 0xa5, 0x30, 0x72]
  , [0xc8, 0xe9, 0x14, 0xd4, 0xd6, 0xeb, 0x91, 0x9b, 0xfb, 0x9f, 0xca, 0x46, 0x07, 0xd5, 0x8d, 0xf5]
  , [0xbf, 0x99, 0xd7, 0x90, 0x52, 0xef, 0xe0, 0xf6, 0x08, 0x52, 0x85, 0xfb, 0x5a, 0x4b, 0xbf, 0xa1]
  , [0xee, 0xb8, 0x2d, 0x31, 0xa6, 0xbe, 0x48, 0x7b, 0x81, 0xfb, 0xf7, 0x1e, 0x1e, 0xc3, 0xed, 0xa9]
  , [0x4a, 0xde, 0x6d, 0x4c, 0xf0, 0x23, 0x36, 0x24, 0xb4, 0x88, 0xb7, 0x56, 0x6e, 0xd8, 0xde, 0x4a]
  , [0x9f, 0x80, 0x9b, 0x6d, 0x24, 0xf1, 0xfc, 0x99, 0xde, 0x02, 0x32, 0x1d, 0xd6, 0xa9, 0x3e, 0xd5]
  , [0x02, 0xa8, 0x75, 0x65, 0xc4, 0x92, 0xbf, 0x60, 0x3f, 0xb4, 0xc4, 0xc1, 0xe8, 0x09, 0xdc, 0x8f]
  , [0xc9, 0x9e, 0x9d, 0x53, 0xa8, 0x7f, 0xb0, 0x9c, 0xd9, 0x36, 0x50, 0x1b, 0x0b, 0xd9, 0x07, 0x1a]
  , [0x45, 0x2e, 0xab, 0xe3, 0x6e, 0xbb, 0xa8, 0xac, 0x56, 0x6f, 0x66, 0x2a, 0xf8, 0xdd, 0x7c, 0x6f]
  , [0xd1, 0x08, 0x4f, 0xbe, 0x9b, 0x27, 0x89, 0x41, 0x85, 0x0e, 0xa1, 0x25, 0x81, 0x82, 0x2f, 0x39]
  , [0xeb, 0xa5, 0xfd, 0xba, 0x2f, 0x33, 0xc9, 0x52, 0x60, 0xa0, 0x97, 0x3a, 0xfd, 0xed, 0x94, 0xa5]
  , [0x07, 0xa2, 0x79, 0xf8, 0x18, 0xd7, 0x87, 0x4c, 0x13, 0xb2, 0xd7, 0x9a, 0x45, 0xfa, 0xfb, 0x81]
  , [0xfd, 0xe2, 0xec, 0x3a, 0x8a, 0x23, 0xa5, 0x78, 0xdc, 0x07, 0x1e, 0xe4, 0xeb, 0x5b, 0x95, 0x2e]
  , [0xd7, 0x50, 0x2c, 0x14, 0x2c, 0x10, 0x38, 0x84, 0x57, 0xec, 0x1c, 0x4d, 0x49, 0x9f, 0x58, 0x19]
  , [0xeb, 0xb5, 0x2f, 0x80, 0xb4, 0x05, 0x0b, 0xf2, 0x04, 0x64, 0x4e, 0x11, 0x89, 0x88, 0x2d, 0x6e]
  , [0xfd, 0x5b, 0xe5, 0x23, 0x32, 0x9e, 0x59, 0xa0, 0x1e, 0x8b, 0x17, 0x5e, 0xfb, 0x96, 0x27, 0x8d]
  , [0xb7, 0x0e, 0x59, 0xa3, 0xda, 0xed, 0x89, 0xc7, 0x29, 0x98, 0x4f, 0xaa, 0x37, 0x4c, 0x59, 0xce]
  , [0x5b, 0x3f, 0x55, 0xcb, 0x2a, 0xfc, 0x4f, 0x90, 0x94, 0x98, 0x38, 0x15, 0x51, 0xd4, 0x01, 0x09]
  , [0xb5, 0x63, 0xcb, 0xd2, 0xd2, 0xbc, 0x23, 0x1c, 0x45, 0xf9, 0x60, 0x2d, 0xa6, 0x83, 0xf5, 0x79]
  , [0xc5, 0xf5, 0x3f, 0x4f, 0x56, 0xdb, 0x3f, 0x7f, 0xe0, 0xe3, 0x03, 0xf7, 0xc8, 0x15, 0xd7, 0x93]
  , [0xbb, 0x92, 0x34, 0x05, 0xf4, 0x02, 0x08, 0xd7, 0x10, 0x1e, 0x8b, 0x57, 0xec, 0x26, 0x0d, 0xa8]
  , [0x1f, 0xe3, 0xa7, 0x42, 0x1b, 0x84, 0xcb, 0xa5, 0x69, 0x22, 0x69, 0xbe, 0x47, 0x30, 0xbb, 0xbd]
  , [0xf2, 0x6f, 0xd5, 0x78, 0x59, 0x0c, 0x0c, 0x14, 0x13, 0x51, 0xd0, 0xb4, 0xc1, 0x49, 0xc1, 0x28]
  , [0x07, 0x51, 0x5d, 0x0d, 0x59, 0x6b, 0x44, 0x19, 0xc8, 0xbb, 0x07, 0x19, 0x74, 0x1f, 0xa2, 0x82]
  , [0x60, 0x99, 0x07, 0xb1, 0x8c, 0xc6, 0xc9, 0xa2, 0x55, 0x04, 0xe2, 0x67, 0xe7, 0x89, 0x0a, 0xa6]
  , [0x7a, 0x6f, 0x0f, 0x03, 0xa6, 0x44, 0x17, 0x23, 0x8a, 0x81, 0x06, 0x74, 0x24, 0x10, 0x87, 0xd5]
  , [0x6c, 0xa5, 0x59, 0x1b, 0x32, 0x12, 0xca, 0x74, 0x1d, 0x2f, 0xdc, 0x24, 0x7a, 0x59, 0xc3, 0x29]
  , [0x57, 0x93, 0xb2, 0x30, 0x59, 0x63, 0xd0, 0x0e, 0xb7, 0x4c, 0x62, 0x7a, 0x4f, 0x3d, 0x02, 0x5e]
  , [0xab, 0xa3, 0x28, 0x2a, 0xa6, 0x4a, 0xa6, 0xf8, 0x19, 0xbe, 0x07, 0x13, 0x88, 0xa9, 0x57, 0x49]
  , [0x12, 0xad, 0x3b, 0xfc, 0xd4, 0xe5, 0x1d, 0xc4, 0xcb, 0xa0, 0x9c, 0x50, 0x0c, 0xb1, 0xe1, 0xc0]
  , [0x57, 0xc4, 0xea, 0x82, 0xc0, 0x3c, 0x30, 0xb3, 0x0e, 0x20, 0xd4, 0x09, 0x03, 0x61, 0x49, 0x49]
  , [0x87, 0xf2, 0x12, 0xf7, 0x27, 0x17, 0xdf, 0x3b, 0x2f, 0x78, 0x16, 0x70, 0x20, 0x60, 0x5a, 0x3b]
  , [0xc8, 0xa3, 0xb7, 0x19, 0xbc, 0xd4, 0x7f, 0xc0, 0x2a, 0x3b, 0xaa, 0xb9, 0x48, 0x90, 0x46, 0x67]
  , [0xed, 0x53, 0x93, 0xf2, 0x5c, 0x29, 0x46, 0xe9, 0x7f, 0xbc, 0x78, 0x3b, 0x99, 0x77, 0x84, 0xa0]
  , [0xa8, 0x3c, 0xa3, 0x94, 0x57, 0xc2, 0x69, 0x8b, 0x2b, 0x30, 0x3c, 0x09, 0x28, 0xe9, 0x4b, 0xe4]
  , [0x6d, 0xb5, 0x49, 0xaa, 0xae, 0x77, 0xef, 0x64, 0x0d, 0x8a, 0x66, 0x46, 0x38, 0x73, 0x28, 0x2f]
  , [0x1d, 0xfa, 0x04, 0x63, 0x27, 0xa3, 0xb1, 0xf3, 0xa6, 0x16, 0xe4, 0x28, 0x7a, 0x2e, 0xc5, 0xe1]
  , [0x51, 0xf9, 0xab, 0xff, 0xb0, 0xaa, 0xc5, 0xd4, 0xbf, 0x9c, 0xcb, 0xec, 0x04, 0x71, 0x60, 0x5a]
  , [0xc8, 0x80, 0xac, 0xa2, 0x74, 0x90, 0x86, 0xb6, 0xbe, 0xaa, 0x4d, 0x29, 0x6f, 0x48, 0xff, 0x21]
  , [0x23, 0xe3, 0x2e, 0x57, 0x2b, 0x11, 0x8f, 0x57, 0x0a, 0x0e, 0x03, 0x78, 0xd1, 0x21, 0x02, 0x05]
  , [0x0b, 0x4b, 0x43, 0x00, 0xe6, 0x06, 0x0b, 0x65, 0x11, 0x24, 0x87, 0x35, 0x0a, 0xe1, 0x5e, 0xbd]
  , [0xf2, 0xae, 0x1e, 0x21, 0x53, 0xc1, 0x15, 0x9f, 0x38, 0x75, 0x35, 0xda, 0xc2, 0xa1, 0xc3, 0x8f]
  , [0x10, 0x3f, 0xe3, 0xfc, 0xbd, 0xb4, 0x54, 0x8c, 0xa3, 0x89, 0x43, 0x52, 0x26, 0xb1, 0xe8, 0x36]
  , [0xab, 0xc3, 0x9c, 0x66, 0x10, 0x36, 0xab, 0xa7, 0x95, 0x7c, 0x49, 0x59, 0x55, 0x68, 0xf6, 0xef]
  , [0xf0, 0x79, 0x03, 0x32, 0xad, 0xd4, 0xd1, 0x48, 0xfe, 0xec, 0xcd, 0x6d, 0xff, 0xd9, 0x9b, 0x74]
  , [0xa3, 0x0c, 0xac, 0xe7, 0x7b, 0x50, 0xd8, 0x6d, 0x17, 0x8d, 0x59, 0x28, 0xe1, 0x2f, 0x7c, 0xae]
  , [0x5e, 0x5b, 0x63, 0x0d, 0xa6, 0x23, 0x8e, 0x00, 0x0b, 0x57, 0x89, 0xda, 0x9c, 0x93, 0x7b, 0xe8]
  , [0x9d, 0xbf, 0xe6, 0x9e, 0xef, 0xb8, 0x37, 0xa6, 0xeb, 0xe5, 0x44, 0x00, 0x55, 0x2e, 0x86, 0x5d]
  , [0x4f, 0x63, 0x7c, 0xe9, 0xdf, 0x28, 0x7e, 0x59, 0x93, 0x40, 0x91, 0x4d, 0xd6, 0x4b, 0x59, 0x75]
  , [0xc9, 0xb8, 0xa1, 0x58, 0x9a, 0x7f, 0x48, 0x22, 0x69, 0x9c, 0xe8, 0x81, 0xb4, 0x3a, 0xff, 0x52]
  , [0xc0, 0x53, 0x2e, 0xe6, 0xd0, 0x89, 0x1e, 0xec, 0x6f, 0x14, 0x2d, 0x7f, 0xfa, 0xb3, 0xf9, 0xdf]
  , [0x32, 0x4d, 0x73, 0x4e, 0x0a, 0x9a, 0xf0, 0x73, 0x5a, 0xe1, 0xfa, 0x73, 0x19, 0xc4, 0x64, 0x71]
  , [0x3e, 0xc2, 0x8b, 0x91, 0x6f, 0x36, 0xd0, 0xde, 0x9f, 0xb8, 0x37, 0xb1, 0x98, 0xb1, 0xe2, 0xfd]
  , [0x85, 0x7c, 0x3f, 0x7b, 0x41, 0x05, 0xcd, 0xac, 0xb2, 0x14, 0xb9, 0xc7, 0x52, 0xfd, 0x72, 0xff]
  , [0x39, 0xff, 0xb0, 0x7b, 0x44, 0x23, 0xab, 0x84, 0x66, 0x62, 0xb2, 0x27, 0xe9, 0x39, 0xdf, 0x83]
  , [0x5d, 0x85, 0xcf, 0x3c, 0x60, 0x5d, 0x95, 0x08, 0xd1, 0x73, 0x34, 0x0a, 0x20, 0x2d, 0xe1, 0xfd]
  , [0xd6, 0x06, 0x89, 0xae, 0xec, 0x14, 0x57, 0x20, 0x59, 0xa2, 0xc8, 0xc6, 0x07, 0x8e, 0x2e, 0xb2]
  , [0x15, 0x30, 0x5d, 0xcc, 0xdf, 0xce, 0xe8, 0x19, 0x85, 0x93, 0xab, 0x6b, 0x25, 0xfe, 0x8b, 0x8e]
  , [0x61, 0xf4, 0x96, 0x25, 0xc2, 0x30, 0xfa, 0xbd, 0x2e, 0x04, 0x54, 0x37, 0x7e, 0x46, 0xa5, 0x54]
  , [0x30, 0x86, 0xaf, 0x94, 0xe4, 0x7d, 0xfd, 0x9a, 0x1e, 0x4e, 0x9d, 0x17, 0x84, 0x5b, 0xc8, 0x24]
  , [0x24, 0x49, 0xd5, 0x6e, 0x3d, 0x53, 0xb6, 0x84, 0x4d, 0x40, 0x5c, 0xe7, 0xb6, 0x54, 0xe8, 0x4d]
  , [0xb6, 0x15, 0x81, 0x36, 0x3d, 0x78, 0xc8, 0x7d, 0xd5, 0xd1, 0xe7, 0x49, 0xfd, 0x87, 0x2f, 0x48]
  , [0x5b, 0x5c, 0x4e, 0x3c, 0x0e, 0xd1, 0xc6, 0x9a, 0x5d, 0x18, 0x9d, 0x51, 0xe0, 0xaf, 0x98, 0x3c]
  , [0x3c, 0x0a, 0x38, 0x3f, 0x9f, 0x27, 0x7a, 0xa8, 0x16, 0xda, 0x98, 0xd0, 0x3f, 0x6c, 0x7e, 0x19]
  , [0xbb, 0x0c, 0x5a, 0xa1, 0xb0, 0xec, 0x04, 0x08, 0xe1, 0xc5, 0xfb, 0xe9, 0x17, 0xf9, 0x92, 0x14]
  , [0x10, 0x51, 0x56, 0x85, 0x8e, 0xc9, 0xeb, 0x98, 0x9e, 0x49, 0x67, 0xca, 0xcd, 0x13, 0x0c, 0x86]
  , [0xf0, 0x57, 0x6a, 0xb8, 0x06, 0x03, 0x95, 0xde, 0x98, 0xeb, 0x5f, 0x8e, 0x5e, 0x9b, 0x9c, 0xcd]
  , [0x97, 0x70, 0xe7, 0x8d, 0xca, 0x39, 0x66, 0xe9, 0x94, 0xe0, 0xad, 0x07, 0x2a, 0x7e, 0xac, 0x19]
  , [0xfe, 0x3d, 0xe7, 0x65, 0x2f, 0xaa, 0x55, 0x32, 0xbb, 0x8e, 0xae, 0xe1, 0x5f, 0xa1, 0x14, 0x7f]
  , [0xa7, 0xfd, 0x75, 0xfd, 0x40, 0x0b, 0x23, 0xc8, 0x51, 0x1b, 0xdf, 0x77, 0xa3, 0xa1, 0xe7, 0xf1]
  , [0xb6, 0x63, 0x42, 0x97, 0x04, 0x0d, 0x88, 0x73, 0x55, 0xbd, 0x52, 0x88, 0x62, 0xd0, 0xdb, 0x25]
  , [0x56, 0xa9, 0xc3, 0x17, 0xe4, 0xef, 0xee, 0x2c, 0x0f, 0x40, 0xd4, 0x8e, 0x3b, 0x52, 0xf9, 0x52]
  , [0xd1, 0xf6, 0x05, 0x69, 0xf7, 0xd6, 0xc3, 0x1f, 0xd5, 0xfe, 0x14, 0x3d, 0xd0, 0xd9, 0x03, 0x38]
  , [0xab, 0x61, 0xbd, 0x21, 0x66, 0xc6, 0xc2, 0xf7, 0x93, 0xcf, 0xb7, 0x52, 0x1f, 0x41, 0x64, 0x40]
  , [0xe0, 0x24, 0x72, 0x1d, 0xb8, 0xa6, 0x1f, 0x68, 0xc4, 0xbc, 0x1f, 0xca, 0x31, 0x37, 0x2e, 0x53]
  , [0xfa, 0x13, 0x85, 0xea, 0xb9, 0x9e, 0x83, 0x6f, 0x52, 0xff, 0x5f, 0xb7, 0x57, 0xb0, 0x0c, 0xfb]
  , [0x7c, 0x0c, 0x96, 0xad, 0xa2, 0x8d, 0x81, 0xa2, 0x3f, 0xdd, 0x52, 0xa0, 0xfe, 0xba, 0x18, 0xfa]
  , [0x41, 0x46, 0xdb, 0x75, 0x42, 0xaa, 0xb7, 0xa3, 0x39, 0x2c, 0x4a, 0xf7, 0x0d, 0xb7, 0x7e, 0xe2]
  , [0x5c, 0x00, 0xcd, 0xe9, 0x6e, 0x13, 0x87, 0xaa, 0x83, 0xdb, 0x41, 0x44, 0xfc, 0x4f, 0x22, 0x6f]
  , [0xd6, 0xf2, 0xcb, 0x1c, 0xf4, 0x27, 0x46, 0xe5, 0x2d, 0xc9, 0x19, 0x36, 0x57, 0xbf, 0xa6, 0x3b]
  , [0xb3, 0xd0, 0xe8, 0xe7, 0x8b, 0x78, 0x5c, 0x8a, 0x73, 0x26, 0x12, 0xa6, 0x29, 0xe9, 0xd5, 0x9c]
  , [0x03, 0x90, 0x39, 0x76, 0x74, 0x91, 0xb6, 0xd1, 0xe6, 0xcc, 0xf4, 0x13, 0x19, 0x87, 0x5f, 0x77]
  , [0x98, 0xe4, 0x0a, 0xaa, 0x07, 0x5b, 0x32, 0x96, 0xb7, 0xcf, 0x08, 0x8c, 0xb9, 0xd1, 0xff, 0xc3]
  , [0x1d, 0x4c, 0x48, 0x18, 0xc4, 0xd0, 0x3c, 0xfe, 0xde, 0xbf, 0xe1, 0xc6, 0x74, 0xc1, 0x54, 0xa5]
  , [0xf0, 0x09, 0x1b, 0x5f, 0xc7, 0x88, 0xef, 0x33, 0x57, 0x93, 0x33, 0x8e, 0x04, 0x60, 0x02, 0x30]
  , [0xdb, 0xb4, 0xf2, 0x81, 0x22, 0x1e, 0x8e, 0xa9, 0xa4, 0xe5, 0x78, 0x99, 0xf2, 0x4a, 0xc9, 0x6e]
  , [0x27, 0xb3, 0x0f, 0x4c, 0x9c, 0x61, 0x19, 0x65, 0xd2, 0x80, 0xdf, 0xde, 0xf6, 0x42, 0xca, 0x19]
  , [0xc1, 0xe2, 0x1b, 0x80, 0x4f, 0xa0, 0x55, 0xdc, 0x61, 0x29, 0xa7, 0xef, 0x4b, 0x39, 0x42, 0xbd]
  , [0x27, 0x47, 0x9b, 0xd4, 0xd6, 0xb2, 0x22, 0x93, 0xd6, 0x27, 0x16, 0x53, 0xfc, 0x73, 0xb3, 0xf7]
  , [0x61, 0x5e, 0x34, 0x76, 0x6a, 0x66, 0x34, 0x3b, 0xbb, 0x6b, 0xc0, 0xe0, 0x36, 0xba, 0x8f, 0x36]
  , [0x4d, 0x43, 0x11, 0xc0, 0x7c, 0x93, 0x28, 0xa6, 0xd7, 0xb7, 0x6b, 0xbe, 0xbd, 0x08, 0xf6, 0x56]
  , [0xc4, 0x03, 0xdc, 0x2c, 0xf9, 0x62, 0x39, 0xf7, 0xd4, 0x37, 0x62, 0x08, 0x82, 0xd0, 0xd5, 0x40]
  , [0x79, 0xee, 0xd5, 0xfa, 0x9c, 0x5a, 0xc8, 0x3d, 0x97, 0x2c, 0x73, 0xed, 0xa6, 0xfc, 0xe2, 0x84]
  , [0x18, 0x0e, 0xd3, 0x27, 0xba, 0x6d, 0x76, 0xd4, 0x2e, 0xf7, 0x96, 0x02, 0xdf, 0xd9, 0x23, 0x61]
  , [0xd4, 0x12, 0x73, 0x28, 0xa6, 0x2f, 0x95, 0x50, 0x19, 0x33, 0x60, 0x3f, 0xad, 0xf2, 0xd1, 0x59]
  , [0x92, 0xa0, 0xba, 0x33, 0x48, 0xfc, 0xb0, 0x56, 0x3f, 0xbf, 0x73, 0xd2, 0x7b, 0x1e, 0xfd, 0x38]
  , [0x95, 0x2b, 0x46, 0xf3, 0x64, 0x87, 0xe2, 0xb9, 0xce, 0x11, 0x48, 0x17, 0x02, 0xf1, 0xbb, 0x49]
  , [0x4a, 0x81, 0x6b, 0x05, 0x5f, 0x89, 0x1a, 0x4f, 0xf0, 0x82, 0xac, 0xe3, 0x69, 0x5d, 0x3c, 0x13]
  , [0xcb, 0x76, 0x1b, 0xb8, 0x7b, 0xff, 0x03, 0x58, 0x83, 0x69, 0xa9, 0xa8, 0x2e, 0x0f, 0xfa, 0x2e]
  , [0x06, 0x6d, 0xc2, 0x70, 0x0d, 0xe0, 0xdf, 0x11, 0xf2, 0xa3, 0xb7, 0xd3, 0xe9, 0x1f, 0x53, 0x17]
  , [0x27, 0x3b, 0xa4, 0xff, 0x21, 0x25, 0x8c, 0xf9, 0x37, 0xaf, 0xb1, 0xe8, 0x5e, 0x91, 0x7a, 0x42]
  , [0x11, 0x2c, 0x0a, 0xe1, 0x3f, 0x74, 0x92, 0xd2, 0xac, 0x2b, 0xfa, 0xd7, 0xfd, 0x04, 0xb7, 0xef]
  , [0x99, 0x70, 0x5f, 0x50, 0x20, 0xca, 0xb0, 0xf6, 0xb0, 0x95, 0x3f, 0xaa, 0xe9, 0x67, 0x55, 0x59]
  , [0xf4, 0x79, 0xd4, 0x3a, 0xb7, 0x75, 0x83, 0xa4, 0x12, 0xbb, 0x09, 0x69, 0x83, 0x72, 0x80, 0x0c]
  , [0x83, 0x0c, 0x2b, 0x6f, 0x44, 0x71, 0x77, 0xfb, 0xd1, 0x6c, 0x0e, 0x7c, 0x63, 0x83, 0x7b, 0x18]
  ]

aesDecrypt :: B.ByteString -> Maybe B.ByteString
aesDecrypt bs = do
  guard $ B.length bs >= 0x800
  let (cipherData, cipherFooter) = B.splitAt (B.length bs - 0x800) bs
      makeKey k = case cipherInit k of
        CryptoPassed cipher -> Just (cipher :: AES128)
        _                   -> Nothing
  iv <- makeIV $ B.replicate 16 0
  cipher <- makeKey $ head keys
  let footer = ctrCombine cipher iv cipherFooter
      keyIndex = sum $ map (B.index footer) [4..7]
  key <- makeKey $ keys !! fromIntegral keyIndex
  return $ ctrCombine key iv cipherData

-- TODO also port the FsbDecrypter class
