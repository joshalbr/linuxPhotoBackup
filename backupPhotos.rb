#!/usr/bin/ruby

require 'aws-sdk'
require 'optparse'
require 'date'
require 'yaml'
require_relative 'lib/photostore'
require_relative 'lib/s3client'

def validate_options(options)
  if options[:directory].empty?
    puts "You must specify at least one directory, options specified #{options.inspect}"
    exit 1
  end
end

def get_options
  # Set default options
  options = {
    rescan: false,
    directory: [],
    only_images: false,
    threads: 1,
    verbose: false,
    filename: '/var/tmp/picture-data-cache.json',
    aws: {}
  }

  # The YAML file can take any command line options
  configFile = Dir.home + '/.photobackuprc.yaml'
  if File.readable?(configFile)
    options.merge!(YAML.load(File.open(configFile)))
  end

  opt_parser = OptionParser.new do |opts|
    opts.banner = "Usage: #{ARGV[0]} [options]"

    opts.on('-d', '--directory Directory', 'Required | Directory to scan (can specify multiples)') do |d|
      options[:directory] << d
    end
    opts.on('-u', '--create-uniq-hash-directory Directory', String, 'Optional | Create a hard link tree to the photos at this directory') do |u|
      options[:uniq_dir] = u
    end
    opts.on('-b', '--create-by-date-directory Directory', String, 'Optional | Create a symlink tree to the uniq photos at this directory') do |b|
      options[:by_date_dir] = b
    end
    opts.on('-r', '--rescan', 'Optional | Purge existing database and scan only these directories') do |e|
      options[:rescan] = true
    end
    opts.on('-i', '--only-images', 'Optional | Skip non-image files') do |e|
      options[:only_images] = true
    end
    opts.on('-t', '--threads NumberOfThreads', Integer, "Optional | Threads to use (default=#{options[:threads]})") do |t|
      options[:threads] = t
    end
    opts.on('-v', '--verbose', 'Optional | Log additonal information out to the terminal') do |v|
      options[:verbose] = true
    end
    opts.separator('Data Store Options')
    opts.on('-f', '--use-file Filename', String, 'Optional | Use a file for the photo datastore') do |f|
      options[:filename] = f
    end
    opts.separator('AWS Options')
    opts.on('-a', '--access-key Key', String, 'Optional | The access key to access the S3 backup') do |a|
      options[:aws][:access_key_id] = a
    end
    opts.on('-s', '--secret-key Key', String, 'Optional | The secret key to access the S3 backup') do |s|
      options[:aws][:secret_access_key] = s
    end
    opts.on('--region Region', String, 'Optional | The aws region for the S3 bucket') do |region|
      options[:aws][:region] = region
    end
    opts.on('-p', '--s3-path PathToS3', String, 'Optional | The path in the format buckname/path/to/backup') do |p|
      options[:s3path] = p
    end
    # TODO: add restore options.
  end.parse!

  validate_options(options)

  options[:logger] = Logger.new(STDOUT)
  options[:logger].level = Logger::INFO unless options[:verbose]

  options
end

# Standard entry point into Ruby from the command line
if __FILE__ == $0
  options = get_options

  photos = PhotoStore.new(options)
  options[:directory].each { |dir| photos.addDirectory(dir) }
  photos.syncWrite

  photos.makeHashDirectoryTree(options[:uniq_dir]) unless options[:uniq_dir].nil?
  photos.makeDateDirectoryTree(options[:by_date_dir]) unless options[:by_date_dir].nil?

  if options[:s3path] && options[:uniq_dir]
    s3client = S3Client.new(options)
    s3client.syncToS3(options[:uniq_dir], options[:s3path])
  end
end
