# frozen_string_literal: true

#
# Copyright (C) 2013 - present Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.
#

module FeatureFlags
  def self.included(base)
    base.has_many :feature_flags, as: :context, dependent: :destroy
  end

  def feature_enabled?(feature)
    # This method is doing a bit more than initially appears. 🤞 this helps you in your
    # future travels, fellow spelunker.
    #
    # persist_result - takes the feature state, logs it to Datadog, then returns it.
    #
    # The feature state is determined by three different cases:
    #   1. the context's id is zero, in which case it should always be false
    #   2. feature lookup fails, in which case it should always be false
    #   3. feature lookup succeeds, in which case it should be the evaluation of enabled?
    persist_result(feature, !id&.zero? && !!lookup_feature_flag(feature)&.enabled?)
  end

  def feature_allowed?(feature)
    flag = lookup_feature_flag(feature)
    return false unless flag

    flag.enabled? || flag.can_override?
  end

  def set_feature_flag!(feature, state)
    feature = feature.to_s
    flag = feature_flags.find_or_initialize_by(feature: feature)
    flag.state = state
    @feature_flag_cache ||= {}
    @feature_flag_cache[feature] = flag
    flag.save!
    association(:feature_flags).reset
  end

  def allow_feature!(feature)
    set_feature_flag!(feature, Feature::STATE_DEFAULT_OFF)
  end

  def enable_feature!(feature)
    set_feature_flag!(feature, Feature::STATE_ON)
  end

  def disable_feature!(feature)
    set_feature_flag!(feature, Feature::STATE_OFF)
  end

  def reset_feature!(feature)
    self.feature_flags.where(feature: feature.to_s).destroy_all
  end

  def feature_flag_cache_key(feature)
    ['feature_flag3', self.class.name, self.global_id, feature.to_s].cache_key
  end

  def feature_flag_cache
    Rails.cache
  end

  # return the feature flag for the given feature that is defined on this object, if any.
  # (helper method.  use lookup_feature_flag to test policy.)
  def feature_flag(feature, skip_cache: false)
    return nil unless self.id

    self.shard.activate do
      if self.feature_flags.loaded?
        self.feature_flags.detect{|ff| ff.feature == feature.to_s}
      elsif skip_cache
        self.feature_flags.where(feature: feature.to_s).first
      else
        result = RequestCache.cache("feature_flag", self, feature) do
          feature_flag_cache.fetch(feature_flag_cache_key(feature)) do
            # keep have the context association unloaded in case we can't marshal it
            FeatureFlag.where(feature: feature.to_s).polymorphic_where(:context => self).first
          end
        end
        result.context = self if result
        result
      end
    end
  end

  # each account that needs to be searched for a feature flag, in priority order,
  # starting with site admin
  def feature_flag_account_ids
    return [Account.site_admin.global_id] if is_a?(User)
    return [] if self.is_a?(Account) && self.site_admin?

    cache = self.is_a?(Account) && root_account? ? MultiCache.cache : Rails.cache
    RequestCache.cache('feature_flag_account_ids', self) do
      shard.activate do
        cache.fetch(['feature_flag_account_ids', self].cache_key) do
          chain = account_chain(include_site_admin: true).dup
          chain.shift if is_a?(Account)
          chain.reverse.map(&:global_id)
        end
      end
    end
  end

  # find the feature flag setting that applies to this object
  # it may be defined on the object or inherited
  def lookup_feature_flag(feature, override_hidden: false, skip_cache: false, hide_inherited_enabled: false, inherited_only: false)
    feature = feature.to_s
    feature_def = Feature.definitions[feature]
    raise "no such feature - #{feature}" unless feature_def
    return nil unless feature_def.applies_to_object(self)

    return nil if feature_def.visible_on.is_a?(Proc) && !feature_def.visible_on.call(self)
    return return_flag(feature_def, hide_inherited_enabled) unless feature_def.can_override? || feature_def.hidden?

    is_root_account = self.is_a?(Account) && self.root_account?
    is_site_admin = self.is_a?(Account) && self.site_admin?

    # inherit the feature definition as a default unless it's a hidden feature
    retval = feature_def.clone_for_cache unless feature_def.hidden? && !is_site_admin && !override_hidden

    @feature_flag_cache ||= {}
    return return_flag(@feature_flag_cache[feature], hide_inherited_enabled) if @feature_flag_cache.key?(feature) && !inherited_only

    # find the highest flag that doesn't allow override,
    # or the most specific flag otherwise
    accounts = feature_flag_account_ids.map do |id|
      # optimizations for accounts we likely already have loaded (including their feature flags!)
      next Account.site_admin if id == Account.site_admin.global_id
      next Account.current_domain_root_account if id == Account.current_domain_root_account&.global_id

      account = Account.new
      account.id = id
      account.shard = Shard.shard_for(id, self.shard)
      account.readonly!
      account
    end

    all_contexts = (accounts + [self]).uniq
    all_contexts -= [self] if inherited_only
    all_contexts.each do |context|
      flag = context.feature_flag(feature, skip_cache: context == self && skip_cache)
      next unless flag

      retval = flag
      break unless flag.can_override?
    end

    # if this feature requires root account opt-in, reject a default or site admin flag
    # if the context is beneath a root account
    if retval && (retval.state == Feature::STATE_DEFAULT_OFF || retval.hidden?) && feature_def.root_opt_in && !is_site_admin &&
        (retval.default? || retval.context_type == 'Account' && retval.context_id == Account.site_admin.id)
      if is_root_account
        # create a virtual feature flag in corresponding default state state
        retval = self.feature_flags.temp_record feature: feature, state: 'off' unless retval.hidden?
      else
        # the feature doesn't exist beneath the root account until the root account opts in
        if inherited_only
          return nil
        else
          return @feature_flag_cache[feature] = nil
        end
      end
    end

    @feature_flag_cache[feature] = retval unless inherited_only
    return_flag(retval, hide_inherited_enabled)
  end

  def return_flag(retval, hide_inherited_enabled)
    return nil unless retval

    unless hide_inherited_enabled && retval.enabled? && !retval.can_override? && (
      # Hide feature flag configs if they belong to a different context
      (!retval.default? && (retval.context_type != self.class.name || retval.context_id != self.id)) ||
      # Hide flags that are forced on in config as well
      retval.default?
    )
      retval
    end
  end

  private
  def persist_result(feature, result)
    InstStatsd::Statsd.increment("feature_flag_check", tags: { feature: feature, enabled: result.to_s})
    result
  end
end

