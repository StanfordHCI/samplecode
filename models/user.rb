# == Schema Information
#
# Table name: users
#
#  id                      :integer          not null, primary key
#  name                    :string(255)
#  email_address           :string(255)      not null
#  provider                :string(255)
#  uid                     :string(255)
#  created_at              :datetime         not null
#  updated_at              :datetime         not null
#  token                   :string(255)
#  refresh_token           :string(255)
#  access_token_expires_at :datetime
#  always_bcc_self         :boolean          default(FALSE)
#  time_zone               :string(255)      default("Pacific Time (US & Canada)"), not null
#  acted_at                :datetime
#  access_token_updated_at :datetime
#

class User < ActiveRecord::Base
  include ActiveModel::ForbiddenAttributesProtection
  include Nameable
  rolify

  attr_accessible :provider, :uid, :name, :email_address, :send_from_email_address_id, :refresh_token, :access_token_expires_at, :always_bcc_self, :role_ids, :time_zone, :sync_contacts_with_google

  has_many :campaigns, dependent: :destroy
  has_many :templates, through: :campaigns
  has_many :emails, through: :contacts
  has_many :conflict, through: :contacts
  has_many :contacts, dependent: :destroy
  has_many :notifications, dependent: :destroy
  has_many :assistant_assignments, dependent: :destroy
  has_many :assigned_campaigns, through: :assistant_assignments, source: :campaign
  has_many :email_addresses, dependent: :destroy
  has_many :spreadsheet, through: :campaigns
  
  scope :registered, where('provider IS NOT NULL AND uid IS NOT NULL')
  scope :active_within_last_week, lambda { where("acted_at >= :date", date: 1.week.ago) }
  scope :having_invalid_credentials, joins(:notifications).where(notifications: {type: InvalidCredentialsErrorNotification})
  scope :having_permanent_fetching_error, joins(:notifications).where(notifications: {type: PermanentFetchingErrorNotification})
  scope :has_role, lambda{|role| includes(:roles).where(:roles => { :name=>  role})}
  scope :by_recency, order('users.created_at DESC')

  validates :email_address, presence: true, uniqueness: true, email: true
  validates_inclusion_of :time_zone, in: ActiveSupport::TimeZone.zones_map(&:name)

  def self.admins
    has_role :admin
  end

  def self.assistants
    has_role :assistant
  end

  def self.should_idle
    registered.active_within_last_week - having_invalid_credentials - having_permanent_fetching_error
  end

  def self.should_fetch
    registered - having_invalid_credentials
  end

  def self.create_with_omniauth auth
    email_address = auth.deep_find 'email'
    user = find_or_initialize_by_email_address(email_address).tap do |user|
      user.provider = auth.deep_find 'provider'
      user.uid = auth.deep_find 'uid'

      # make the first user an admin
      user.add_role :admin if User.count == 0

      # give stanford users their always bcc, because they use stanford's SMTP server
      user.always_bcc_self = user.has_custom_SMTP_server?
    end
    user.save! and return user
  end

  def is_registered? # technically one of provider and uid would probably be enough
    provider.present? and uid.present?
  end

  def has_invalid_credentials?
    notifications.where(type: InvalidCredentialsErrorNotification).any?
  end

  def access_token= token
    write_attribute(:token, token)
  end

  def access_token
    SessionsController.refresh_access_token_for_user(self) if access_token_expired?
    token
  end

  def access_token_expired?
    return true if access_token_expires_at.blank?
    access_token_expires_at < (Time.now + 5.minutes) # access_token will be expired within 5 minutes or has already expired
  end

  def has_custom_SMTP_server?
    # TODO actually allow custom servers; not just stanford
    send_from_email_address.end_with? 'stanford.edu'
    false #TODO Temporarily disabled due to errors
  end

  def user
    self
  end


  # Email addresses
  def send_from_email_address
    send_from_email_address = EmailAddress.where(id: read_attribute(:send_from_email_address_id)).first.try(:content)
    send_from_email_address ||= email_address
  end

  def find_email_address content
    email_addresses.where(content: content).first
  end

  def has_email_address content
    email_address == content or find_email_address(content).present?
  end

  # Email fetching

  def fetch_emails
    Resque.enqueue(MessageFetcher, self.id)
    MessageFetchingNotification.add self
  end

  def message_identifier_suffix
    '.' + id.to_s + '@' + ENV['message-id-identifier']
  end

  def known_thrids
    emails.having_thrid.uniq.pluck(:thrid)
  end

  def known_uids
    emails.having_uid.uniq.pluck(:uid).compact.map(&:to_i)
  end

  def campaign_labels
    campaigns.syncing_labels.pluck(:slug).map {|slug| "myriad/" + slug}
  end

  # Email fetching related maintenance (used in future rake task)
  def header_message_ids_with_missing_uid_or_thrid
    emails.where(delivery_status: Email::DS_ON_GMAIL).where("uid IS NULL OR thrid IS NULL").select("header_message_id").map { |m| m.header_message_id }
  end

end
