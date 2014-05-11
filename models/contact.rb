# == Schema Information
#
# Table name: contacts
#
#  id            :integer          not null, primary key
#  first_name    :string(255)
#  last_name     :string(255)
#  email_address :string(255)      not null
#  user_id       :integer          not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  slug          :string(255)      not null
#  emails_count  :integer          default(0), not null
#

# == Schema Information
#
# Table name: contacts
#
#  id            :integer          not null, primary key
#  first_name    :string(255)
#  last_name     :string(255)
#  email_address :string(255)      not null
#  user_id       :integer          not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#

class Contact < ActiveRecord::Base
  extend FriendlyId
  friendly_id :display_name, use: :slugged
  include Nameable
  belongs_to :user
  attr_accessible :email_address, :first_name, :last_name, :google_id, :etag, :master_copy
  auto_strip_attributes :first_name, :last_name, :email_address, :google_id, :etag

  has_many :templates_contacts, dependent: :destroy
  has_many :templates, through: :templates_contacts
  has_many :conversations, dependent: :destroy
  has_many :campaigns, through: :conversations
  has_many :spreadsheets, through: :campaigns
  has_many :emails, dependent: :destroy
  has_many :values, dependent: :destroy
  has_many :searches, through: :campaigns
  has_one :conflict, dependent: :destroy

  before_validation :normalize_email_address
  validates :email_address, presence: true, uniqueness: {scope: 'user_id'}, email: true
  validates :user_id, presence: true
  validates :user, associated: true


  def name
    if first_name or last_name
      [first_name, last_name].join(" ")
    else
      nil
    end
  end

  def conversation_for_campaign campaign
    conversations.where(campaign_id: campaign.id).first!
  end

  def values_for_campaign campaign
    values.joins(:key).where(:keys => {:campaign_id => campaign.id})
  end

  def value_for_key key
    value = Value.find_by_key_and_contact(key, self)
    value.try(:content)
  end

  # The complicated logic in this method mostly serves the purpose of not saving
  # a value if not needed - because with a spreadsheet that's expensive.
  def set_value_for_key key, content
    value = Value.find_by_key_and_contact(key, self)
    if value.present?
      if value.content != content
        value.content = content
        value.save!
        Resque.enqueue(SpreadsheetValueSetter, value.id) if key.campaign.spreadsheet.present?
      end
    else # value == nil
      if content.present?
        value = Value.create! content: content, key: key, contact: self
        Resque.enqueue(SpreadsheetValueSetter, value.id) if key.campaign.spreadsheet.present?
      end
    end
    value
  end

  def self.email_exists? user_id, email
    user = User.find(user_id)
    contact = user.contacts.where(email_address: email).first
    return contact
  end

  def self.google_id_exists? user_id, google_id
    user = User.find(user_id)
    contact = user.contacts.where(google_id: google_id).first
    return contact
  end


  def self.find_or_new_or_update options, spreadsheet = nil
    email_address = options[:email_address]
    first_name = options[:first_name]
    last_name = options[:last_name]
    user = options[:user]

    if user.present?
      contact = user.contacts.where(email_address: email_address).first
    end

    if contact.present?
      if spreadsheet != nil
        if contact.first_name != first_name || contact.last_name != last_name
          Conflict.add_conflict contact, options, spreadsheet
        end
      else #no spreadsheet, so update
        contact.first_name = first_name if first_name.present?
        contact.last_name = last_name if last_name.present?
        contact.save!
        contact.update_in_google
      end
    else
      contact = Contact.new do |contact|
        contact.email_address = email_address
        contact.first_name = first_name
        contact.last_name = last_name
        contact.user = user
      end # new
      contact.add_to_google
    end # if
    return contact
  end

  # Create the contact in Google
  # If Google create correctly the contact, the `contact` google attributes are added
  # Else, the `contact` is define as the master copy
  #
  # @return [Contact] the `contact` with google attributes added or `master_copy: true`
  def add_to_google
    if user.sync_contacts_with_google?
      response = GoogleContact.create self

      if response && response.status_code == 201 # everything ok (post)
        self.set_auth_attributes(response.to_xml)
        self.master_copy = false
        self.save!
      else
        self.update_attributes(master_copy: true)
      end
    else
      self.update_attributes(master_copy: true)
    end
  end


  # Update the contact in Google
  # If Google update correctly the contact, the `etag` of the contact is updated
  # Else, the contact is define as the master copy
  #
  # @return [Contact] the contact with `etag` or `master_copy: true`
  def update_in_google
    if user.sync_contacts_with_google?
      attributes = {:first_name => first_name,
                    :last_name => last_name,
                    :google_id => google_id,
                    :etag => etag}

      response = GoogleContact.update(self, attributes)

      if response && response.status_code == 200
        etag = response.to_xml.root.attributes['gd:etag']
        self.update_attributes(etag: etag, master_copy: false)
      else
        self.update_attributes(master_copy: true)
      end
    else
      self.update_attributes(master_copy: true)
    end
  end

# a hash of all key/value pairs + names and email_address. Basically a serialization.
  def keys_hash_for_campaign campaign
    keys_hash = {'email_address' => email_address, 'first_name' => first_name, 'last_name' => last_name}
    values_for_campaign(campaign).inject(keys_hash) { |hash, value| hash[value.key.name] = value.content; hash }
  end

  def set_auth_attributes(response)
    self.etag = response.root.attributes['gd:etag']
    self.google_id = response.elements.first.text
  end

  def set_entry_attributes(entry, attributes)
    self.attributes = attributes
    gd_name = entry.elements['gd:name']
    if gd_name
      gd_name.elements['gd:givenName'].text = self.first_name
      gd_name.elements['gd:familyName'].text = self.last_name
    else
      entry.elements['title'].text = self.first_name + " " + self.last_name
    end

    entry.root.attributes['gd:etag'] = self.etag
    entry.elements['gd:email'].attributes['address'] = self.email_address
    return entry
  end

  def self.sync current_user
    if current_user.sync_contacts_with_google?
      resource = Notification.new
      resource.user = current_user
      Resque.enqueue(ContactSyncer, current_user.id)
      ContactSyncReportNotification.resolve resource
      ContactSyncErrorNotification.resolve resource
      ContactSyncingNotification.add resource
    end
  end

  protected

  def normalize_email_address
    self.email_address = self.email_address.remove_all_whitespace if self.email_address.present?
  end

end

