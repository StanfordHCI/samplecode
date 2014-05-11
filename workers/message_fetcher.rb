class MessageFetcher < AbstractWorker
  @queue = self.queue_name

  def self.perform user_id, time_period=nil
    # Get fetching timelimit from gmail.yml
    time_period ||= eval(YAML.load_file("#{Rails.root}/config/custom/gmail.yml")[Rails.env]['fetching_timelimit'])
    message_fetcher = Fetcher.new user_id, time_period
    message_fetcher.fetch_all
  end

end # class MessageFetcher
