class LabelSetter

  def initialize
    @logger = Logger.new 'log/label_setter.log'
    @logger.formatter = Logger::Formatter.new

    @gmail = Gmail.new
  end

  def set_campaign_label_for_email email_id, number_of_tries
    begin
      @logger.debug "Setting label for email with id #{email_id}..."
      email = Email.find(email_id)
      raise "Email not found!" if email.blank?

      if email.uid.blank?
        @logger.warn "UID not found - reenqueueing ID Fetcher."
        Resque.enqueue(IdFetcher, email.user.id, [email.id], number_of_tries + 1, true)
        return
      end

      campaign = email.campaign
      raise "Campaign not found." if campaign.blank?
      return if !campaign.sync_labels?

      @user = campaign.user
      connect
      
      # Make sure we have the "myriad" label set
      ensure_presence_of_myriad_label

      # Select Allmail folder and assign campaign label to email(s)
      select_allmail_folder
      @gmail.add_label_for_uids [email.uid.to_i], [campaign.label_for_gmail]
      @logger.error "Done setting label for email with id #{email_id}."

    rescue Exception => exception
      @logger.error "Error during label setting: #{exception.message}"
      FetchingExceptionNotification.add @user, exception
    ensure
      # Disconnect from IMAP server
      begin
        @gmail.disconnect
        @logger.debug "Terminated IMAP connection.\n"
      rescue Exception => exception
        @logger.error "Error while closing the connection: #{exception.message}\n"
      end
    end

  end

  def create_campaign_label campaign_id
    begin
      campaign = Campaign.find(campaign_id)
      return if campaign.nil? or !campaign.sync_labels?
      @user = campaign.user
      connect

      ensure_presence_of_myriad_label
      @gmail.create_mailbox campaign.label_for_gmail rescue nil

    rescue Exception => exception
      @logger.error "Error during fetching: #{exception.message}"
      FetchingExceptionNotification.add @user, exception
    ensure
      # Disconnect from IMAP server
      begin
        @gmail.disconnect
        @logger.debug "Terminated IMAP connection.\n"
      rescue Exception => exception
        @logger.error "Error while closing the connection: #{exception.message}\n"
      end
    end
  end

  # Makes sure the myriad label exists and creates it otherwise
  # (so that the label we are about to assign can be nested below it)
  def ensure_presence_of_myriad_label
    @gmail.status "myriad", ["MESSAGES"]
  rescue Net::IMAP::NoResponseError => exception
    @gmail.create_mailbox "myriad"
  end

  def connect
    @gmail.connect @user
    @logger.debug "Authenticated user #{@user.display_name}..."
  rescue Exception => exception
    @logger.error "Error while setting up the IMAP connection: #{exception.message}"
    raise exception
  end

  def select_allmail_folder
    # Try to identify "All Mail" folder (has different names in internationalized versions of Gmail).
    # Access in examine mode (read-only).
    begin
      folder_name = @gmail.find_folder :Allmail
      if !folder_name.nil?
        @gmail.select_folder(folder_name)
      else
        @logger.error "Error!"
        # err_msg = "All Mail folder not found."
        # AllmailFolderUnavailableErrorNotification.add @user, err_msg
        raise "All Mail folder not found!"
      end
    rescue Exception => exception
      @logger.error "Error while identifying and selecting 'All mail' folder: #{exception.message}"
      raise exception
    else
      # AllmailFolderUnavailableErrorNotification.resolve @user
    end
  end

end
