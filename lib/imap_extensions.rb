require "rubygems"
require "fileutils"

# Adds functionality to fetch messages based on google
# message and thread identififers, as well as search
# for these.
# Monkeypatch Net::IMAP to support GMail IMAP extensions.
# http://code.google.com/apis/gmail/imap/
# https://github.com/nu7hatch/gmail/issues/43
module Net
  class IMAP

    # Implement GMail XLIST command
    def xlist(refname, mailbox)
      synchronize do
        send_command("XLIST", refname, mailbox)
        return @responses.delete("XLIST")
      end
    end

    class ResponseParser
      def response_untagged
        match(T_STAR)
        match(T_SPACE)
        token = lookahead
        if token.symbol == T_NUMBER
          return numeric_response
        elsif token.symbol == T_ATOM
          case token.value
          when /\A(?:OK|NO|BAD|BYE|PREAUTH)\z/ni
            return response_cond
          when /\A(?:FLAGS)\z/ni
            return flags_response
          when /\A(?:LIST|LSUB|XLIST)\z/ni  # Added XLIST
            return list_response
          when /\A(?:QUOTA)\z/ni
            return getquota_response
          when /\A(?:QUOTAROOT)\z/ni
            return getquotaroot_response
          when /\A(?:ACL)\z/ni
            return getacl_response
          when /\A(?:SEARCH|SORT)\z/ni
            return search_response
          when /\A(?:THREAD)\z/ni
            return thread_response
          when /\A(?:STATUS)\z/ni
            return status_response
          when /\A(?:CAPABILITY)\z/ni
            return capability_response
          else
            return text_response
          end
        else
          parse_error("unexpected token %s", token.symbol)
        end
      end

      def response_tagged
        tag = atom
        match(T_SPACE)
        token = match(T_ATOM)
        name = token.value.upcase
        match(T_SPACE)
        #puts "AAAAAAAA  #{tag} #{name} #{resp_text} #{@str}"
        return TaggedResponse.new(tag, name, resp_text, @str)
      end

      def msg_att n
        match(T_LPAR)
        attr = {}
        while true
          token = lookahead
          case token.symbol
          when T_RPAR
            shift_token
            break
          when T_SPACE
            shift_token
            token = lookahead
          end
          case token.value
          when /\A(?:ENVELOPE)\z/ni
            name, val = envelope_data
          when /\A(?:FLAGS)\z/ni
            name, val = flags_data
          when /\A(?:X-GM-LABELS)\z/ni  # Added X-GM-LABELS extension
            name, val = flags_data
          when /\A(?:INTERNALDATE)\z/ni
            name, val = internaldate_data
          when /\A(?:RFC822(?:\.HEADER|\.TEXT)?)\z/ni
            name, val = rfc822_text
          when /\A(?:RFC822\.SIZE)\z/ni
            name, val = rfc822_size
          when /\A(?:BODY(?:STRUCTURE)?)\z/ni
            name, val = body_data
          when /\A(?:UID)\z/ni
            name, val = uid_data
          when /\A(?:X-GM-MSGID)\z/ni  # Added X-GM-MSGID extension
            name, val = uid_data
          when /\A(?:X-GM-THRID)\z/ni  # Added X-GM-THRID extension
            name, val = uid_data
          else
            parse_error("unknown attribute `%s' for {%d}", token.value, n)
          end
          attr[name] = val
        end
        return attr
      end
    end
  end
end


class GMail

  @@mailbox_cache = "#{ENV['HOME']}/.gmail-cache"
  @@buf_size  = 10
  @@ignore_attr = [:Allmail, :Spam, :Trash, :Noselect]
  @@ignore_mailbox = []

  class Mailbox
    attr_accessor :uidvalidity, :uidmax, :uidnext, :name, :num_seen, :num_indexed, :num_bad

    def initialize(name)
      @name = name
      @uidmax = -100
      @num_seen = 0
      @num_indexed = 0
      @num_bad = 0
    end
  end

  def initialize(user, pass)
    puts "Connecting to Gmail ..."
    @imap = Net::IMAP.new "imap.gmail.com", 993, :ssl => true
    puts "Login as #{user} ..."
    @imap.login user, pass
    puts "Obtaining list of all labels"
    @mailbox_list =  @imap.xlist("", "*")
    @mailboxes = load_mailboxes

    # Install response handler to catch UIDPLUS reponse UID
    @imap.add_response_handler { |resp|
     # puts "DEBUG: #{resp}"
      if resp.kind_of?(Net::IMAP::TaggedResponse)
       if resp.data.is_a?Net::IMAP::ResponseText and resp.data.code and resp.data.code.name == "APPENDUID"
         puts "Append Message UID #{resp.data.code.data}"
       end
     end
    }

    @running = true
  end

  def start
    @mailbox_list.each { |mailbox|
      sync_new(mailbox)
    }
  end

  def stop
    @running = false
  end

  # Method that checks a mailbox for new messages and 
  # feed them to Heliotrope. Assumes Heliotrope service
  # is running at http://localhost:8042
  def sync_new(mailbox)
      # Skip any mailbox with attributes in ignore_attr
      return if ! (mailbox.attr & @@ignore_attr).empty?
      return if !@running

      name = Net::IMAP.decode_utf7(mailbox.name)
      cache = @mailboxes[name] || Mailbox.new(name)

      puts "Examining mailbox #{name}"

      begin
        @imap.examine(mailbox.name)
      rescue => e
        puts "Failed to examine mailbox: #{e}"
        return
      end

      uidvalidity = @imap.responses["UIDVALIDITY"][-1]
      uidnext = @imap.responses["UIDNEXT"][-1]

      if cache.uidvalidity != uidvalidity
        puts "UIDVALIDITY differ, rescaning all mailbox"
        ids = @imap.search(["NOT", "DELETED"])
      else
        if (cache.uidmax + 1 == uidnext)
          puts "No new messages"
          return
        end
        puts "UIDVALIDITY match, get new messages only"
        ids = ((cache.uidmax + 1) .. uidnext).to_a
      end

      puts "; got #{ids.size} messages"

      while(!(block = ids.shift(@@buf_size)).empty?)

        break if ! @running
        puts "; requesting messages #{block.first}..#{block.last} from server"

        msgs = @imap.fetch((block.first..block.last), ["UID", "X-GM-MSGID", "X-GM-THRID", "X-GM-LABELS", "FLAGS", "RFC822"])

        if ! msgs
          puts msgs
          next
        end

        msgs.each { |msg|
          break if ! @running

          body = msg.attr["RFC822"]
          body.force_encoding("binary") if body.respond_to?(:force_encoding) 
          body.gsub("\r\n", "\n")

          labels = msg.attr["X-GM-LABELS"].push(name).collect { |label| Net::IMAP.decode_utf7(label.to_s) }

          state = msg.attr["FLAGS"].collect { |flag| flag.to_s.downcase.to_sym }
          puts state

          begin
            response = RestClient.post "http://localhost:8042/message.json", 
                                     { :body => body, :labels => labels, :state => state, :mailbox => name },
                                     { :content_type => :json, :accept => :json}
          rescue RestClient::ResourceNotFound => e
            puts "Warning: resource not found"
            next
          rescue => e
            puts "Failed to communicate with heliotrope : #{e.class}"
            @running = false
            break
          end

          puts response 
          response = JSON.parse(response)

          if response["response"] == "ok"
            if response["status"] == "seen"
              cache.num_seen += 1
            else
              cache.num_indexed += 1
            end
          else
            cache.num_bad += 1
            puts "Error for message: " + response["error_message"]
          end

          cache.uidmax = [cache.uidmax || 0, msg.attr["UID"]].max
        }
      end

      puts "Store mailbox #{name} cache"
      cache.uidnext = uidnext
      cache.uidvalidity = uidvalidity
      @mailboxes[name] = cache
      save_mailboxes
  end

  private

  def load_mailboxes
    if File.exists?(@@mailbox_cache)
       File.open(@@mailbox_cache,"rb") { |fd|
         @mailboxes = Marshal.load(fd.read)
       }
    else
      @mailboxes = {}
    end
    @mailboxes
  end

  def save_mailboxes
    File.open(@@mailbox_cache,"wb") { |fd|
      fd << Marshal.dump(@mailboxes)
    }
    @mailboxes
  end

end

if __FILE__ == $0

  if ARGV.size < 2
    puts "Usage:  gmail.rb  <username> <password>"
    exit 0
  end

  gmail = GMail.new(ARGV[0], ARGV[1])

  trap("SIGINT") {   puts "-- SIGINT Stopping --";   gmail.stop  }
  trap("SIGTERM") {   puts "-- SIGTERM Stopping --";   gmail.stop  }
  trap("SIGPIPE") {   puts "-- SIGPIPE Stopping --";   gmail.stop  }
  trap("SIGHUP") {   puts "-- SIGHUP Stopping --";   gmail.stop  }

  gmail.start

end

# GMail API allows search via X-GM-RAW extension
#puts "Search via X-GM-RAW extension"
#ids = imap.search(["X-GM-RAW", "to: hsanson"])

# Example how to append a message to GMail
#puts "Test append message"
#imap.append("inbox", <<EOF.gsub(/\n/, "\r\n"), [:Seen], Time.now)
#Subject: hello
#From: shugo@ruby-lang.org
#To: shugo@ruby-lang.org

#hello world
#EOF
