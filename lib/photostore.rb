#!/usr/bin/ruby

require 'digest'
require 'aws-sdk'
require 'fileutils'
require 'json'
require 'exifr/jpeg'
require 'date'
require 'progressbar'
require 'parallel'
require 'mimemagic'

# This class abstracts the data store for photo data.
# This uses a flat file, but could easily be modified to use a DB or DDB
class PhotoStore
  CACHE_FILE='/var/tmp/picture-data-cache.json'

  def initialize(options = {})
    @rescan = options.fetch(:rescan, false)
    @only_images = options.fetch(:only_images, false)
    @filename = options.fetch(:filename, CACHE_FILE)
    @logger = options.fetch(:logger, Logger.new(STDOUT))
    @threads = options.fetch(:threads, 1)
    @file_mutex = Mutex.new
    loadFromFile
  end

  # Gets file metadata using a hash or filename lookup (cannot be both!)
  #
  # @param options [Hash] :hash - Specifies the hash, :filename the filename
  #
  # @return [Hash] File metadata hash, if exists
  def getFile(options)
    if options[:hash] && options[:filename]
      raise "Specified both hash and filename to getFile"
    elsif options[:hash].nil? && options[:filename].nil?
      raise "Specified neither hash nor filename to getFile"
    end

    if !options[:hash].nil?
      @photos_by_hash[options[:hash]]
    elsif !options[:filename].nil?
      @photos_by_filename[options[:filename]]
    end
  end

  # Adds a file into the metadata datastore
  #
  # @param filename [String] The path of an existing file
  def addFile(filename)
    return if getFile(filename: filename)

    hash = Digest::SHA256.hexdigest(File.read(filename))

    @file_mutex.synchronize {
      @photos_by_hash[hash] ||= {}
      @photos_by_hash[hash]['hash'] = hash
      @photos_by_hash[hash]['size'] = File.size(filename)
      @photos_by_hash[hash]['files'] ||= []
      @photos_by_hash[hash]['files'] << filename
      @photos_by_hash[hash]['date'] = loadExif(filename)
      @photos_by_filename[filename] = @photos_by_hash[hash]
    }
  end

  # Recursively adds all files in a directory to the metadata datastore
  #
  # @param directory [String] A directory to scan for file metadata
  def addDirectory(directory)
    @logger.info("Adding directory #{directory}")
    Dir.chdir(directory) do
      files = Dir.glob("**/*").select do |file|
        # NOTE: Selection here is all non-directory files.  This will includes things
        # like movies, photo db files, etc. unless the only-images option is passed
        @only_images ? !File.directory?(file) && MimeMagic.by_magic(File.read(file)).type.match('image') : !File.directory?(file)
      end

      progressbar = ProgressBar.create(total: files.size)
      completed = 0

      Parallel.each(files, in_threads: @threads) do |file|
        addFile(File.expand_path(file))
        @file_mutex.synchronize { completed += 1 }
        progressbar.progress = completed
      end
    end
  end

  # Returns the entire metadata datastore
  #
  # @return [Hash] The metadata datastore
  def getAllFiles
    @photos_by_hash
  end

  # Writes the metadata datastore to disk
  def syncWrite
    outfile = File.open(@filename, 'w')
    outfile.puts(@photos_by_hash.to_json)
  end

  # Creates a symlink directory tree structure based on exif date from the datastore
  #
  # @param start_directory [String] The directory to build the symlink tree in
  def makeDateDirectoryTree(start_directory = '.')
    progressbar = ProgressBar.create(total: getAllFiles.keys.size)
    getAllFiles.each_with_index do |(hash, file_info), index|
      if file_info['date'].nil?
        date_path = "Unknown"
        destination_filename = hash
      else
        begin
          date = DateTime.parse(file_info['date'].to_s)
          date_path = sprintf("%4d/%02d", date.year, date.month)
          destination_filename = sprintf("%4d-%02d-%02d-%02d-%02d-%02d-%s", date.year, date.month, date.day, date.hour, date.min, date.sec, hash)
        rescue => e
          @logger.warn "Error, invalid date specified in exif for file #{file_info['files'].first}"
          date_path = "Unknown"
          destination_filename = hash
        end
      end

      directory = start_directory + '/' + date_path
      file = "#{directory}/#{destination_filename}.#{getExtension(file_info['files'].first)}"
      FileUtils::mkdir_p directory unless Dir.exists?(directory)
      begin
        FileUtils.ln_s(file_info['hashfile'], file) unless File.exists?(file)
      rescue => e
        @logger.warn "Unable to create link for file #{file}, have you created the unique hashfile?"
      end
      progressbar.progress = index
    end
  end

  # Creates hardlinks in a tree structure by sha256 hash, to the original pictures
  #
  # @param start_directory [String] The directory to build the tree of hard linked files
  def makeHashDirectoryTree(start_directory = '.')
    progressbar = ProgressBar.create(total: getAllFiles.keys.size)
    getAllFiles.each_with_index do |(hash, file_info), index|
      directory = start_directory + '/' + hash[0..2]
      destination_filename = hash
      file = "#{directory}/#{destination_filename}.#{getExtension(file_info['files'].first)}"
      FileUtils::mkdir_p directory unless Dir.exists?(directory)
      begin
        FileUtils.ln(file_info['files'].first, file) unless File.exists?(file)
        addHashFileLocation(hash, file)
      rescue => e
        @logger.warn "Unable to make link for #{file} to #{file_info['files'].first}, exception #{e}"
      end
      progressbar.progress = index
    end
  end

  # Calculates the total size used by all files
  # NOTE: We assume there are no hard links between the existing files
  #
  # @return [Integer] The size in bytes of all of the files
  def calculateTotalSize
    size = 0
    @photos_by_hash.each do |hash, info|
      size += info['size'] * info['files'].size
    end

    size
  end

  # Calculates the size of the files if they are deduplicated (hard linked)
  # NOTE: We do assume there are no hard links between the existing files
  #
  # @return [Integer] The size in bytes of the files assuming there was only one copy
  def calculateDedupeSize
    size = 0
    @photos_by_hash.each do |hash, info|
      size += info['size']
    end

    size
  end

  private
  @photos_by_hash
  @photos_by_filename
  @filename

  # Explicitly adds the location of the hashed, hard-linked file on disk
  #
  # @param hash [String] The SHA256 hash of the file
  # @param hashFile [String] The location on the disk where this file is hardlinked by the above hash
  def addHashFileLocation(hash, hashFile)
    @photos_by_hash[hash]['hashfile'] = hashFile
  end

  # Gets the file extension of the original file
  #
  # @param filename [String] The filename to parse
  #
  # @return [String] The extension
  def getExtension(filename)
    split_file = filename.split('.')
    # TODO: We assume if there is no extension, this is a JPEG, because this is an image utility
    # For more robustness, we could read in the file and look at the mimetype
    if split_file.size < 2
      'jpg'
    else
      split_file[-1]
    end
  end

  # Loads the metadata datastore from disk
  def loadFromFile
    @photos_by_hash ||= {}
    @photos_by_filename ||= {}
    if File.readable?(@filename) && !@rescan
      @photos_by_hash = JSON.parse(File.read(CACHE_FILE))
      @photos_by_hash.each do |hash, info|
        info["files"].each do |file|
          @photos_by_filename[file] = info
	      end
      end
    end
  end

  # Loads the exif date data from a file
  #
  # @param filename [String] The filename to load the exif data from
  #
  # @return [String] The date from the exif metadata
  def loadExif(filename)
    begin
      exif = EXIFR::JPEG.new(filename)
    rescue
      return nil
    end

    # All 3 dates might exist, grab them in order of preference
    date = exif.date_time_original
    if date.nil?
      date = exif.date_time
    elsif date.nil?
      date = exif.date_time_digitized
    end

    date.to_s
  end
end
