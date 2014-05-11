class String

  def double_bracketize
    "{{#{self}}}"
  end

  def bracketed_message_id
    "<#{self}>"
  end

  def is_upcase?
    self == self.upcase
  end

  def titlecase_words
    self.split(" ").collect{|word| word[0] = word[0].upcase; word}.join(" ")
  end

  def ellipsisize minimum_length = 4, edge_length = 3
    return self if self.length < minimum_length or self.length <= edge_length*2
    edge = '.'*edge_length
    mid_length = self.length - edge_length*2
    gsub(/(#{edge}).{#{mid_length},}(#{edge})/, '\1...\2')
  end

  def to_bool
    return true if self == true || self =~ (/(true|t|yes|y|1)$/i)
    return false if self == false || self.blank? || self =~ (/(false|f|no|n|0)$/i)
    raise ArgumentError.new("invalid value for Boolean: \"#{self}\"")
  end
  
  def remove_all_whitespace
    self.gsub /\s+/, ''
  end
  
  def similar_to? string_or_symbol
    self.only_characters_and_numbers.downcase == string_or_symbol.to_s.only_characters_and_numbers.downcase
  end
  
  # Finding the complement of the character ranges (upper case, lower case, digits) and translating those to ''.
  def only_characters_and_numbers
    self.tr('^A-Za-z0-9', '')
  end
  
  def first_name
    split.first
  end
  
  def last_name
    if split.count >= 2
      split[1..-1].join(' ')
    end
  end

end

class Hash
  def deep_find key
    key = key.to_s # in case somebody passes us a :symbol
    key?(key) ? self[key] : self.values.inject(nil) do |memo, v|
      memo ||= v.deep_find(key) if v.respond_to?(:deep_find)
    end
  end
end

class Array

  def foldl(accum, &block)
    each { |value| accum = yield(accum, value) }
    return accum
  end
  alias fold :foldl

  def foldr(accum, &block)
    reverse.foldl(accum, &block)
  end
  
  def uniq?
    length == uniq.length
  end
  
  def contains_duplicates?
    not uniq?
  end

end

module Enumerable
  def to_histogram
    inject(Hash.new(0)) { |h, x| h[x] += 1; h}
  end
end

# http://trevorturk.com/2007/12/04/random-records-in-rails/
module ActiveRecord
  class Base
    def self.random
      if (c = count) != 0
        find(:first, :offset =>rand(c))
      end
    end
  end
end

class Mail::Address
  delegate :first_name, :last_name, to: :name, allow_nil: true
end

class File
  def self.unique_filepath filepath
    count = 0
    unique_name = filepath
    while File.exists? unique_name
      count += 1
      unique_name = "#{File.join( File.dirname(filepath), File.basename(filepath, ".*"))}-#{count}#{File.extname filepath}"
    end # while
    unique_name
  end # unique_filepath
end # File
