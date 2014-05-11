class GoogleContact

  def self.create contact
    get_client contact.user
    begin
      response = @gdata_client.post('https://www.google.com/m8/feeds/contacts/default/full', entry(contact))
    rescue Exception => e
      logger.error "Error creating contact in google : #{e}"
    ensure
      return response
    end
  end

  def self.update contact, new_attributes
    get_client contact.user
    begin
      entry = @gdata_client.get(contact.google_id).to_xml
      updated_entry = contact.set_entry_attributes(entry, new_attributes)
      response = @gdata_client.put(contact.google_id, updated_entry)
    rescue Exception => e
      logger.error "Error updating contact in google : #{e}"
    ensure
      return response
    end
  end

  def self.get_all_contacts user
    get_client user
    contacts_xml = @gdata_client.get('https://www.google.com/m8/feeds/contacts/default/full?max-results=900000').to_xml
    return contacts_xml
  end

  def self.delete contact
    get_client contact.user
    begin
      @gdata_client.get(contact.google_id).to_xml
      @gdata_client.headers['If-Match'] = contact.etag # make sure we don't nuke another client's updates
      response = @gdata_client.delete(contact.google_id)
    rescue Exception => e
      logger.error "Error deleting contact in google : #{e}"
    ensure
      return response
    end
  end

  private
  def self.get_client user
    @gdata_client = GData::Client::Contacts.new
    @gdata_client.authsub_token = user.access_token
  end

  def self.entry contact
    if !contact.first_name.nil?
      givenName = "<gd:givenName>#{contact.first_name}</gd:givenName>"
    else
      givenName = ""
    end

    if !contact.last_name.nil?
      familyName = "<gd:familyName>#{contact.last_name}</gd:familyName>"
    else
      familyName = ""
    end

    if !contact.first_name.nil? && !contact.last_name.nil?
      fullName = "<gd:fullName>#{contact.first_name} #{contact.last_name}</gd:fullName>"
    else
      fullName = ""
    end

    entry = <<-EOF
    <atom:entry xmlns:atom='http://www.w3.org/2005/Atom' xmlns:gd='http://schemas.google.com/g/2005'>
      <atom:category scheme='http://schemas.google.com/g/2005#kind' term='http://schemas.google.com/contact/2008#contact'/>
      <gd:name>
        #{givenName}
        #{familyName}
        #{fullName}
      </gd:name>
      <atom:content type='text'>Notes</atom:content>
      <gd:email rel='http://schemas.google.com/g/2005#home' address='#{contact.email_address}'/>
    </atom:entry>
    EOF
    return entry
  end

end