class IMAP

  # When a new email is discovered, a simple 'fetch' is enqueued.
  def self.idle user, logger=nil
    begin
      @gmail = Gmail.new
      @gmail.connect user

      folder_name = @gmail.find_folder :Allmail
      if folder_name.present?
        @gmail.select_folder(folder_name)
      else
        @logger.error "Error!"
        raise "All Mail folder not found!"
      end

      @gmail.idle do |response|
        if response.kind_of? Net::IMAP::ContinuationRequest
          logger.debug "User #{user.id}: IDLEing continues"
        elsif response.kind_of? Net::IMAP::UntaggedResponse
          case response.name
          when 'EXISTS'
            logger.info "User #{user.id}: IDLEing was notified of a new email."
            Resque.enqueue(MessageFetcher, user.id)
          when 'EXPUNGE'
            logger.info "User #{user.id}: IDLEing was notified of an email was expunged."
          else
            logger.debug "User #{user.id}: IDLEing got unknown response: #{response.name},  #{response.raw_data}"
          end # case response.name
        else
          logger.debug "User #{user.id}: IDLEing received unknown response kind #{response.class} : #{response.name},  #{response.raw_data}"
        end # response.kind_of? Net::IMAP::UntaggedResponse
      end # @gmail.idle
    rescue Interrupt
      logger.error "User #{user.id}: IDLEing was interrupted!"
    rescue Net::IMAP::NoResponseError => exception
      if exception.message.include?('Invalid credentials')
        InvalidCredentialsErrorNotification.add user, exception.message
      elsif exception.message.include?('Too many simultaneous connections.')
        PermanentFetchingErrorNotification.add user, exception.message
      end # exception sub types
      logger.error "User #{user.id}: IDLEing raised an Net::IMAP::NoResponseError exception : #{exception.message}"
    rescue Exception => exception
      ExceptionNotification.add user, exception, "Generic exception during IDLEing; not an Interrupt or Net::IMAP::NoResponseError"
      logger.error "User #{user.id}: IDLEing raised an exception: #{exception.message}"
    ensure
      @gmail.idle_done
      @gmail.disconnect
    end # rescue
  end # self.idle user

end