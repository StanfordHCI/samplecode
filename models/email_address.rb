class EmailAddress < ActiveRecord::Base

  attr_accessible :user, :content
  belongs_to :user

  validates :content, presence: true, uniqueness: { scope: 'user_id' }, email: true

  before_destroy do |email_address|
    if user.send_from_email_address == email_address.content
      user.write_attribute(:send_from_email_address_id, nil)
      user.save!
    end
  end

  def to_s
    content
  end

  def self.encode_if_needed(address)
    if address.is_a?(Array)
      # loop back through for each element
      address.compact.map { |a| Encodings.address_encode(a, charset) }.join(", ")
    else
      # find any word boundary that is not ascii and encode it
      encode_non_usascii(address, 'utf-8') if address
    end
  end

  def self.encode_non_usascii(address, charset)
    return address if address.ascii_only? or charset.nil?
    us_ascii = %Q{\x00-\x7f}
    # Encode any non usascii strings embedded inside of quotes
    address = address.gsub(/(".*?[^#{us_ascii}].*?")/) { |s| Encodings.b_value_encode(unquote(s), charset) }
    # Then loop through all remaining items and encode as needed
    tokens = address.split(/\s/)
    map_with_index(tokens) do |word, i|
      if word.ascii_only?
        word
      else
        previous_non_ascii = i>0 && tokens[i-1] && !tokens[i-1].ascii_only?
        if previous_non_ascii #why are we adding an extra space here?
          word = " #{word}"
        end
        Encodings.b_value_encode(word, charset)
      end
    end.join(' ')
  end

end