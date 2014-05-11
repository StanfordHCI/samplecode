#
class Fetcher

  # TODO Load in initializer
  GMAIL_CONFIG = YAML.load_file("#{Rails.root}/config/custom/gmail.yml")[Rails.env]

  # Gmail config (IMAP queries)
  GM_THRID = GMAIL_CONFIG['gm_thrid_attr']
  GM_LABEL = GMAIL_CONFIG['gm_label_attr']
  MSGID_FIELD = GMAIL_CONFIG['message_id_field']
  RFC822 = GMAIL_CONFIG['rfc822_attr']
  UID = GMAIL_CONFIG['uid_attr']
  ATTR = 'attr'

  # Myriad config (set myriad identifier, don't fetch emails w/ certain labels and don't fetch drafts)
  MYRIAD_IGNORE_LABELS = (ENV['imap-ignore-labels'] || "").split(",").each.map {|e| e.strip} + [GMAIL_CONFIG['gm_drafts_label']]

  def initialize user_id, time_period
    @logger = Logger.new 'log/message_fetcher.log'
    @logger.formatter = Logger::Formatter.new

    @logger_id_fetching = Logger.new 'log/id_fetcher.log'
    @logger_id_fetching.formatter = Logger::Formatter.new

    @user = User.find user_id

    time_limit = set_time_limit time_period # Emails are only checked for the time window between time_limit and current time.
    @gmail = Gmail.new(time_limit, MYRIAD_IGNORE_LABELS)

    @logger.debug "Initialized MessageFetcher for user #{@user.display_name} (id: #{@user.id}) with time limit #{time_limit}."
  end

  def fetch_all

    begin
      # During fetching we disable early ConversationObserver to give the late EmailObservers a chance to reply.
      # (Because if we create a conversation during fetching that's ONLY because we have a new email.)
      Conversation.observers.disable ConversationObserver do
        
        # Set up imap session
        connect
  
        # Try to identify "All Mail" folder (has different names in internationalized versions of Gmail).
        # Access in examine mode (read-only).
        select_allmail_folder
  
        fetch_mode_reply # Fetch emails in reply modee
        fetch_mode_conversation # Fetch emails in conversation mode
        fetch_mode_label # Fetch emails in label mode
  
        @logger.info "Done fetching emails for #{@user.display_name} (id: #{@user.id})."
      end # Conversation.observers.disable
    rescue Exception => exception
      if exception.message.include?('Invalid credentials')
        InvalidCredentialsErrorNotification.add @user, exception.message
      else
        @logger.error "Error during fetching: #{exception.message}"
        FetchingExceptionNotification.add @user, exception
      end
    ensure
      Conversation.observers.enable ConversationObserver
      # Disconnect from IMAP server
      begin
        @gmail.disconnect
        @logger.debug "Terminated IMAP connection.\n"
      rescue Exception => exception
        @logger.error "Error while closing the connection: #{exception.message}\n"
      end
      MessageFetchingNotification.resolve @user
    end
  end # fetch_all

  # Fetches emails that are in reply to our current Myriad identifier
  def fetch_mode_reply
    # Get the user-specific myriad identifier (used in header message ids) and search for matching UIDs on Gmail (excluding drafts and MYRIAD_IGNORE_LABELS)
    all_uids_replymode = @gmail.uid_search_by_myriad_identifier @user.message_identifier_suffix
    # Fetch identified emails
    fetch_generic "REPLY", all_uids_replymode
  end # fetch_mode_reply

  # Fetches emails that are part of a conversation we know (i.e. we have the conversation's THRID in our database)
  def fetch_mode_conversation
    # Find all THRIDs we know for this user and search for matching UIDs on Gmail (excluding drafts and MYRIAD_IGNORE_LABELS)
    known_thrids = @user.known_thrids
    return if known_thrids.blank?
    all_uids_conversationmode = @gmail.uid_search_by_thrid known_thrids
    # Fetch identified emails
    fetch_generic "CONVERSATION", all_uids_conversationmode
  end # fetch_mode_conversation

  # Fetches emails that are labeled as belonging to a Myriad campaign
  def fetch_mode_label
    # Gather all campaign-specific labels for this user and search for matching UIDs on Gmail (excluding drafts and MYRIAD_IGNORE_LABELS)
    labels = @user.campaign_labels
    return if labels.blank?
    all_uids_labelmode = @gmail.uid_search_by_labels labels
    # Fetch identified emails
    fetch_generic "LABEL", all_uids_labelmode
  end # fetch_mode_label

  # Takes a list of UIDs and filters for those we don't know yet. Triggers fetching of the remaining emails.
  def fetch_generic mode, all_uids
    @logger.debug "Beginning to fetch in #{mode} mode..."
    if all_uids.present?
      new_uids = filter_known_uids all_uids # Remove all UIDs we already know
      import_emails_by_uids new_uids # Fetch emails for remaining UIDs
    end
    @logger.debug "Done with fetching in #{mode} mode."
  end

  # This method checks for UIDs that we already have in our database and discards them (as we don't want to try to fetch them again).
  def filter_known_uids all_uids
    new_uids = all_uids - @user.known_uids
  end

  # Fetches emails from the Gmail server by their UID and triggers their creation in Myriad.
  def import_emails_by_uids uids
    if uids.present?
      # Fetch emails (incl. metadata) for given UIDs from Gmail
      emails_with_metadata = @gmail.fetch_email_and_metadata_by_uids uids

      if emails_with_metadata.present?
        # Unpack emails and metadata into hash
        mails_with_metadata = unpack_emails_and_metadata emails_with_metadata
        # Sort emails by date (if multiple emails are fetched for a single conversation, this should ensure that each email will find its in_reply_to)
        mails_with_metadata.sort_by {|data| data[:mail].date}
        
        # Trigger import of each email into Myriad database
        mails_with_metadata.each do |mail_with_metadata|
          begin
            # Determine whether this is an EmailIn, EmailOutGmail etc.
            type = determine_email_type mail_with_metadata[:mail]
            next if type.nil?
            @logger.debug "This is a '#{type}'."
          rescue Exception => exception
            @logger.error "Error while determining email type: #{exception.message}"
          end
          begin
            # Trigger creation of email in myriad
            type.create_from_mail! mail_with_metadata
          rescue Exception => exception
            @logger.warn "Could not create email: #{exception.message}"
          end
        end # mails_with_metadata.each
      else
        @logger.warn "Fetching email(s) by just retrieved UID(s) seems to have failed. This shouldn't happen but could be due to a Gmail server error. Please investigate."
      end # if emails_with_metadata.present?
    end # if ids.present?
  end # import_emails_by_uids

  # Checks whether an email is a EmailOutGmail, EmailDsn or EmailIn
  def determine_email_type mail
    # Skip mail if already downloaded
    if @user.emails.find_by_header_message_id mail.message_id
      @logger.debug "Header message ID already present in database: " + mail.message_id
      return nil
    end

    @logger.debug "Discovered unknown header message id: " + mail.message_id.to_s
    
    if @user.has_email_address mail.from.first # Detect email sent by user himself using Gmail
      type = "EmailOutGmail"
    elsif mail.detect_dsn # Detect delivery status notification (usually bounces)
      type = "EmailDsn"
    else # Anything else is assumed to be an EmailIn
      type = "EmailIn"
    end

    # Get class of determined email type (this is a subclass of Email and could be EmailOutGmail, EmailDsn or EmailIn)
    Email::const_get(type)
  end # determine_email_type

  # Receives email data from Gmail and unpacks data into hash (pairing each email with its metadata)
  def unpack_emails_and_metadata emails
    mails_with_metadata = []
    emails.each do |e|
      mail_data = Hash.new
      mail_data[:mail]   = Mail.new(e[ATTR][RFC822])
      mail_data[:uid]    = e[ATTR][UID]
      mail_data[:thrid]  = e[ATTR][GM_THRID]
      mail_data[:labels] = e[ATTR][GM_LABEL]
      mails_with_metadata << mail_data
    end
    mails_with_metadata
  end

  def set_time_limit time_period # TODO: TEST
    if time_period > 0.hours
      time = Time.now - time_period
    else # Pass '0'/negative time period to drop date restriction
      time = Time.at(0)
    end
    time_limit = time.strftime("%d-%b-%Y") # Format for Gmail imap server
  end

  def fetch_ids email_ids
    begin
      connect
      select_allmail_folder
      email_ids.each do |email_id|
        @logger_id_fetching.debug "Fetching id for email with id #{email_id}..."
        email = Email.find(email_id)
        next if email.nil? or email.user != @user
        uid = @gmail.uid_search_by_msgid email.header_message_id, false
        thrid = @gmail.fetch_thrid_by_uid uid if uid.present?

        if uid.present? and thrid.present?
          @logger_id_fetching.debug "Found ids for email #{email_id}; UID: #{uid.to_s}, THRID: #{thrid.to_s}"
          begin
            email.update_attributes(uid: uid, thrid: thrid)
          rescue Exception => exception
            @logger_id_fetching.error "Error when writing IDs to database: #{exception.message}"
            UnexpectedStateNotification.add @user, exception.message, email
          end
        else
          @logger_id_fetching.warn "Was unable to retrieve UID and or THRID."
        end
      end
    rescue Exception => exception
      @logger_id_fetching.error "Error during ID fetching: #{exception.message}"
      FetchingExceptionNotification.add @user, exception
    ensure
      # Disconnect from IMAP server
      begin
        @gmail.disconnect
        @logger_id_fetching.debug "Terminated IMAP connection.\n"
      rescue Exception => exception
        @logger_id_fetching.error "Error while closing the connection: #{exception.message}\n"
      end
    end
  end

  def connect
    begin
      @gmail.connect @user
      InvalidCredentialsErrorNotification.resolve @user
      @logger.debug "Authenticated user #{@user.display_name}..."
    rescue Exception => exception
      @logger.error "Error while setting up the IMAP connection: #{exception.message}"
      raise exception
    end
  end

  def select_allmail_folder
    # Try to identify "All Mail" folder (has different names in internationalized versions of Gmail).
    # Access in examine mode (read-only).
    begin
      folder_name = @gmail.find_folder :Allmail
      if folder_name.present?
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

end # class MessageFetcher
