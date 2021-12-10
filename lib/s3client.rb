require 'aws-sdk'
require 'parallel'

class S3Client
  def initialize(options)
    @client = Aws::S3::Client.new(options[:aws])
    @logger = options.fetch(:logger, Logger.new(STDOUT))
    @threads = options.fetch(:threads, 1)
  end

  # Puts the directory into S3 if the files do not already exist
  # Given that all files are hashed, the same hash should by definition never be a different file
  # NOTE: We do this based on the directory, not the metadata.  If files are added that aren't in the metadata
  # they will by synced as well.
  #
  # @param source_file [String] The file to copy
  # @param destination [String] An S3 URI
  def syncToS3(source, destination)
    Dir.chdir(source) do
      files = Dir.glob("**/*")

      @logger.info "Uploading from #{source} to #{destination}"
      progressbar = ProgressBar.create(total: files.size)
      Parallel.each_with_index(files, in_threads: @threads) do |file, index|
        next if File.directory?(file)
        bucket, path = parseS3URI(destination)
        filepath = [path, file].join('/')

        resp = @client.list_objects_v2(bucket: bucket, prefix: filepath)
        unless resp.key_count == 1
          @logger.debug "Putting file #{file}"
          @client.put_object(body: File.open(file), bucket: bucket, key: filepath)
        end
        progressbar.progress = index
      end
    end
  end

  private
  def parseS3URI(uri)
    # TODO: Support file:// and http://s3.amazonaws.com/ URIs
    unless uri.match(/^s3:\/\//)
      raise 'Unable to parse s3 URI.  At this time, the script only supports s3:// paths'
    end

    split_uri = uri.split('/')
    bucket = split_uri[2]
    path = split_uri[3..-1].join('/')

    return bucket, path
  end
end
