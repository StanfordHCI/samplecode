class CanAccessResque
  def self.matches? request
    return true if Rails.env.development?
    current_user = User.find(request.env.deep_find(:user_id)) if request.env.deep_find(:user_id)
    return false if current_user.blank?
    Ability.new(current_user).can? :manage, Resque
  end
end

class CanAccessAdmin
  def self.matches? request
    current_user = User.find(request.env.deep_find(:user_id)) if request.env.deep_find(:user_id)
    return false if current_user.blank?
    return current_user.has_role? :admin
  end
end
