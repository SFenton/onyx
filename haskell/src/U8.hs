{- |

Written with reference to

  * <http://wiibrew.org/wiki/U8_archive>
  * u8it by icefire: <https://github.com/Plombo/romextract/blob/master/src/u8it.c>

-}
{-# LANGUAGE BangPatterns #-}
module U8 (packU8) where

import           Data.Bifunctor        (first)
import           Data.Binary.Put       (Put, putByteString, putWord16be,
                                        putWord32be, putWord8, runPut)
import           Data.Bits             (shiftR)
import qualified Data.ByteString       as B
import qualified Data.ByteString.Char8 as B8
import qualified Data.ByteString.Lazy  as BL
import           Data.SimpleHandle
import qualified Data.Text             as T
import           Data.Word             (Word32)
import           System.IO             (IOMode (..), SeekMode (..), hFileSize,
                                        hSeek, withBinaryFile)

data U8Folder = U8Folder
  { u8FolderName    :: B8.ByteString
  , u8FolderLevel   :: Int -- 0 for root and root's children, 1 for root's grandchildren, etc.
  , u8FolderFiles   :: [U8File]
  , u8FolderFolders :: [U8Folder]
  }

data U8File = U8File
  { u8FileSize     :: Int
  , u8FileReadable :: Readable
  , u8FileName     :: B8.ByteString
  , u8FileParents  :: [B8.ByteString]
  }

getRoot :: Folder B8.ByteString Readable -> IO U8Folder
getRoot = getFolder [] B8.empty where
  getFolder parents name folder = do
    files <- mapM (getFile $ name : parents) $ folderFiles folder
    folders <- mapM (uncurry $ getFolder $ name : parents) $ folderSubfolders folder
    return U8Folder
      { u8FolderName = name
      , u8FolderLevel = case length parents of
        0 -> 0
        n -> n - 1
      , u8FolderFiles = files
      , u8FolderFolders = folders
      }
  getFile parents (name, readable) = do
    len <- useHandle readable hFileSize
    return U8File
      { u8FileSize     = fromIntegral len
      , u8FileReadable = readable
      , u8FileName     = name
      , u8FileParents  = parents
      }

writeU8 :: FilePath -> U8Folder -> IO ()
writeU8 out root = withBinaryFile out WriteMode $ \hout -> do

  let align a n = case quotRem n a of
        (_, 0) -> n
        (q, _) -> a * (q + 1)
      lookup' x alist = case lookup x alist of
        Nothing -> error $ "writeU8: panic! value not found in lookup table: " ++ show x
        Just y  -> y

  -- string table
  let folderNames d = u8FolderName d :
        (map u8FileName (u8FolderFiles d) ++ concatMap folderNames (u8FolderFolders d))
      nameOffsets _    []       = []
      nameOffsets !off (n : ns) = (n, off) : nameOffsets (off + B.length n + 1) ns
      names = folderNames root
      nameLookup = nameOffsets 0 names
      nameTable = BL.fromChunks $ names >>= \n -> [n, B.singleton 0]

  -- data table
  let pathSizes d
        =  map (\f -> (u8FileName f : u8FileParents f, u8FileReadable f, u8FileSize f, align 0x20 $ u8FileSize f)) (u8FolderFiles d)
        ++ concatMap pathSizes (u8FolderFolders d)
      dataOffsets _    []                  = []
      dataOffsets !off ((fp, _, _, aligned) : rest) = (fp, off) : dataOffsets (off + aligned) rest
      datas = pathSizes root
      dataLookup = dataOffsets 0 datas
      writeData (_revPath, readable, size, aligned) = do
        useHandle readable handleToByteString >>= BL.hPut hout
        B.hPut hout $ B.replicate (aligned - size) 0

  -- dir/file nodes
  let nodes = dirToNodes 1 root
      putWord24be :: Word32 -> Put
      putWord24be n = do
        putWord8 $ fromIntegral $ n `shiftR` 16
        putWord16be $ fromIntegral n
      fileToNode f = runPut $ do
        putWord8 0
        putWord24be $ fromIntegral $ lookup' (u8FileName f                  ) nameLookup
        putWord32be $ fromIntegral  (lookup' (u8FileName f : u8FileParents f) dataLookup) + alignedDataOffset
        putWord32be $ fromIntegral $ u8FileSize f
      subdirNodes _  []       = []
      subdirNodes !n (d : ds) = let
        dnodes = dirToNodes n d
        in dnodes ++ subdirNodes (n + length dnodes) ds
      dirToNodes n dir = let
        contents = subdirNodes (n + 1) (u8FolderFolders dir) ++ map fileToNode (u8FolderFiles dir)
        top = runPut $ do
          putWord8 1
          putWord24be $ fromIntegral $ lookup' (u8FolderName dir) nameLookup
          putWord32be $ fromIntegral $ u8FolderLevel dir
          putWord32be $ fromIntegral $ n + length contents
        in top : contents

      headerSize = fromIntegral (length nodes * 12) + fromIntegral (BL.length nameTable) -- nodes size + string table size
      alignedDataOffset = align 0x40 $ 0x20 + headerSize

  BL.hPut hout $ runPut $ do
    putWord32be 0x55AA382D -- tag, "U.8-"
    putWord32be 0x20 -- offset to root node
    putWord32be headerSize
    putWord32be alignedDataOffset
    putByteString $ B.replicate 16 0
  mapM_ (BL.hPut hout) nodes
  BL.hPut hout nameTable
  hSeek hout AbsoluteSeek $ fromIntegral alignedDataOffset
  mapM_ writeData datas

packU8 :: FilePath -> FilePath -> IO ()
packU8 dir fout = crawlFolder dir >>= getRoot . first (B8.pack . T.unpack) >>= writeU8 fout
