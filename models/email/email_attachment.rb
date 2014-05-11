# == Schema Information
#
# Table name: email_attachments
#
#  id           :integer          not null, primary key
#  email_id     :integer          not null
#  file_path    :string(255)      not null
#  file_name    :string(255)      not null
#  content_type :string(255)      not null
#  size         :integer          not null
#

class EmailAttachment < ActiveRecord::Base
  attr_accessible :belongs_to, :content_type, :file_name, :file_path, :size
  
  belongs_to :email
  has_one :contact, through: :email
  has_one :campaign, through: :email
  
  validates :file_name, :content_type, :size, :email_id, presence: true
  validates :email, associated: true
  
  before_destroy :delete_data
  
  def self.attachments_dir
    File.join Rails.root.to_s, 'data', 'email_attachments'
  end
  
  def self.file_path_for_filename filename, email
    File.join EmailAttachment.attachments_dir, email.user.id.to_s, email.campaign.slug, email.contact.slug, filename
  end
  
  def self.create_from_email_and_attachment! email, attachment
    EmailAttachment.create! do |email_attachment|
      # Metadata
      email_attachment.email = email
      email_attachment.file_name = File.basename(File.unique_filepath(EmailAttachment.file_path_for_filename(attachment.filename, email)))
      email_attachment.content_type = attachment.content_type[/[^;]*/] # everything up to first semicolon
      
      # Actual data
      data = attachment.body.decoded
      email_attachment.size = data.size
      email_attachment.write_data data
      
      true # Creation succeeded
    end # create
  end # create_from_email_and_attachment!
  
  def file_path
    EmailAttachment.file_path_for_filename file_name, email
  end
      
  def write_data data
    # first, make sure the directory exists
    directory = File.dirname file_path
    FileUtils.mkdir_p directory
    # then, binarily write the data
    File.open file_path, 'w+b', 0644 do |file| 
      file.write data
    end # File.open
  end # write_data
  
  protected
  
    def delete_data
      begin
        File.delete file_path
      rescue Errno::ENOENT => exception
      end
    end

end
