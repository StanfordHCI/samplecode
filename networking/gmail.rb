require 'imap_extensions'

class Gmail

  # TODO Load in initializer
  GMAIL_CONFIG = YAML.load_file("#{Rails.root}/config/custom/gmail.yml")[Rails.env]

  # Gmail config (authentication)
  GM_SERVER = GMAIL_CONFIG['gm_imap_server']
  GM_PORT = GMAIL_CONFIG['gm_imap_port']
  SSL = GMAIL_CONFIG['ssl_enabled']
  AUTH_MODE = ENV['auth_mode']

  # Gmail config (IMAP queries)
  GM_THRID = GMAIL_CONFIG['gm_thrid_attr']
  GM_LABEL = GMAIL_CONFIG['gm_label_attr']
  GM_RAW = GMAIL_CONFIG['gm_raw_attr']
  GM_RFC822MSGID = GMAIL_CONFIG['gm_rfc822msgid_attr']
  GM_RAW_RFC822MSGID = GM_RAW + " " + GM_RFC822MSGID
  MSGID_FIELD = GMAIL_CONFIG['message_id_field']
  RFC822 = GMAIL_CONFIG['rfc822_attr']
  UID = GMAIL_CONFIG['uid_attr']
  ATTR = 'attr'

  EXCEPTIONS = [Net::IMAP::NoResponseError, Net::IMAP::BadResponseError].freeze

  def initialize since=Time.at(0).to_datetime.strftime("%d-%b-%Y"), ignore_terms=[]
    @ignore_terms = ignore_terms
    @since = since
  end

  def connect user
    # Set up imap session
    @imap = Net::IMAP.new GM_SERVER, GM_PORT, SSL, certs = nil, verify = false
    @imap.authenticate AUTH_MODE, user.email_address, user.access_token
    InvalidCredentialsErrorNotification.resolve user
  end

  def disconnect
    @imap.disconnect
  rescue
    nil
  end

  def find_folder folder_descriptor
    folders = @imap.xlist("", "*/%") # Use "/%" to not query recursively (could be thousands of folders)
    folders.select { |f| f.attr.include?(folder_descriptor) }.map(&:name).first
  end

  def examine_folder folder_name
    @imap.examine folder_name
  end

  def select_folder folder_name
    @imap.select folder_name
  end

  def status folder_name, attributes
    @imap.status folder_name, attributes
  end


  def idle (&block)
    @imap.idle &block
  end

  def idle_done
    @imap.idle_done
  rescue
    nil
  end

  def uid_search_by_myriad_identifier identifier, use_time_limit=true # fetch_mode_reply
    query = build_query("HEADER In-Reply-To", [identifier], use_time_limit)
    @imap.uid_search(query)
  end

  def uid_search_by_thrid thrids, use_time_limit=true  # fetch_mode_conversation
    # Gmail refuses queries which exceed a certain size ("Excessive nesting in command"), so we limit them to 500 THRIDs each
    thrids.in_groups_of(500, false).flat_map do |batch|
      query = build_query(GM_THRID, batch, use_time_limit)
      @imap.uid_search(query)
    end
  end

  def uid_search_by_labels labels, use_time_limit=true  # fetch_mode_label
    query = build_query(GM_LABEL, labels, use_time_limit)
    @imap.uid_search(query)
  end

  def uid_search_by_msgid msgid, use_time_limit=true  # label setter
    query = build_query(GM_RAW_RFC822MSGID, [msgid], use_time_limit, "")
    begin
      @imap.uid_search(query).first
    rescue *EXCEPTIONS => exception
      nil
    end
  end

  def fetch_thrid_by_uid uid
    @imap.uid_fetch([uid], [GM_THRID]).first[ATTR][GM_THRID]
  end

  def fetch_email_and_metadata_by_uids uids # get_emails_by_uid
    @imap.uid_fetch(uids, [UID, GM_THRID, GM_LABEL, RFC822])
  end

  def create_mailbox name
    @imap.create(name)
  end

  def add_label_for_uids uids, labels # label setter
    @imap.uid_store(uids, "+" + GM_LABEL, labels)
  end


  def fetch_msgid_and_thrid_by_uids uids # only used in update_uids_thrids
    @imap.uid_fetch(uids, [MSGID_FIELD, GM_THRID])
  end

  protected

    def build_query attribute, values, use_time_limit, separator=" "
      terms = build_subquery attribute, values, separator
      terms += " NOT " + build_subquery(GM_LABEL, @ignore_terms) if @ignore_terms.any? # Exclude drafts and certain labels from being fetched
      terms += " SINCE #{@since}" if use_time_limit
      return terms
    end

    def build_subquery attribute, values, separator=" "
      terms = ""
      if !values.empty?
        if values.size == 1
          terms = "#{attribute}#{separator}#{values[0]}"
        else
          terms = values.map { |v| "OR #{attribute}#{separator}#{v}"}
          terms[terms.count - 1]['OR '] = ''
          terms = terms.join(" ")
        end
      end
      return terms
    end

end # class Gmail
