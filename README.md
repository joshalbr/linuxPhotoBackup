# Photo Backup Script

This script will scan multiple directories and hash them to identify multiple copies of the same file.  It will also read in EXIF data from the picture as well to get the time the picture was taken.

It can then optionally build a hardlink/symlink directory structure to centralize these disparate directories into one location, and upload that to S3.

## Prerequisites

- Ruby 3 installed
- bundler installed
- Run `bundle`

## Usage

`bundle exec ruby backupPhotos.rb -h`

Required options are only the directory to scan, which will build a metadata file.  AWS Options will infer from your local default config (if not specified in the command line).

Note also there there is an example YAML config file which has all of the options listed.

## Example use case

Suppose I have three directories of photos:
1. /home/user1/Pictures/
2. /home/share/Pictures/
3. /home/user3/Photos Library.photoslibrary/originals

These directories may or may not have the exact same photos, and all of them need to be backed up.

To create the metadata file information:
```
./backupPhotos.rb -d /home/user1/Pictures/ -d /home/share/Pictures/ -d /home/user3/Photos Library.photoslibrary/originals
```

To create a hashed directory structure at /home/share/unique/<hash>:
```
./backupPhotos.rb -d /home/user1/Pictures/ -d /home/share/Pictures/ -d /home/user3/Photos Library.photoslibrary/originals -u /home/share/unique
```

Same command as above, but ALSO create a directory structure with a set of links based on the EXIF dates:
```
./backupPhotos.rb -d /home/user1/Pictures/ -d /home/share/Pictures/ -d /home/user3/Photos Library.photoslibrary/originals -u /home/share/unique -b /home/share/bydate
```

Create the unique hash directory with links to the original files, and back them up to s3:
```
./backupPhotos.rb -d /home/user1/Pictures/ -d /home/share/Pictures/ -d /home/user3/Photos Library.photoslibrary/originals -u /home/share/unique -p s3://bucketname/location
```
