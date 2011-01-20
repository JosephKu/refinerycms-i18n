# Encoding: UTF-8 <-- required, please leave this in.
require 'refinery'
require 'routing-filter'

module Refinery
  module I18n
    class Engine < Rails::Engine
      config.before_initialize do
        require File.expand_path('../i18n-filter', __FILE__)
        require File.expand_path('../i18n-js', __FILE__)
        require File.expand_path('../translate', __FILE__)
      end

      config.to_prepare do
        ::ApplicationController.class_eval do
          def default_url_options(options={})
            ::Refinery::I18n.enabled? ? { :locale => ::I18n.locale } : {}
          end

          prepend_before_filter :find_or_set_locale

          def find_or_set_locale
            if ::Refinery::I18n.enabled?
              if ::Refinery::I18n.has_locale?(locale = params[:locale].try(:to_sym))
                Thread.current[:globalize_locale] = ::I18n.locale = locale
              elsif locale.present? and locale != ::Refinery::I18n.default_frontend_locale
                Thread.current[:globalize_locale] = params[:locale] = I18n.locale = ::Refinery::I18n.default_frontend_locale
                redirect_to(params, :notice => "The locale '#{locale}' is not supported.") and return
              else
                Thread.current[:globalize_locale] = ::I18n.locale = ::Refinery::I18n.default_frontend_locale
              end
            end
          end

          protected :default_url_options, :find_or_set_locale
        end

        ::Admin::BaseController.class_eval do
          # globalize! should be prepended first so that it runs after find_or_set_locale
          prepend_before_filter :globalize!, :find_or_set_locale

          def find_or_set_locale
            if (params[:set_locale].present? and ::Refinery::I18n.locales.include?(params[:set_locale].to_sym))
              ::Refinery::I18n.current_locale = params[:set_locale].to_sym
              redirect_back_or_default(admin_dashboard_path) and return
            else
              ::I18n.locale = ::Refinery::I18n.current_locale
            end
          end

          def globalize!
            Thread.current[:globalize_locale] = (params[:switch_locale] || ::Refinery::I18n.default_frontend_locale)
          end

          protected :find_or_set_locale, :globalize!
        end
      end

      config.after_initialize do
        ::Refinery::I18n.setup! if defined?(RefinerySetting) and RefinerySetting.table_exists?

        Refinery::Plugin.register do |plugin|
          plugin.name = "refinery_i18n"
          plugin.version = %q{0.9.9.1}
          plugin.hide_from_menu = true
          plugin.always_allow_access = true
        end
      end

    end

    class << self

      attr_accessor :enabled, :current_locale, :locales, :default_locale, :default_frontend_locale, :built_in_locales

      def enabled?
        # cache this lookup as it gets very expensive.
        if defined?(@enabled) && !@enabled.nil?
          @enabled
        else
          @enabled = RefinerySetting.find_or_set(:i18n_translation_enabled, true, {
            :callback_proc_as_string => %q{::Refinery::I18n.setup!},
            :scoping => 'refinery'
          })
        end
      end

      def current_locale
        unless enabled?
          ::Refinery::I18n.current_locale = ::Refinery::I18n.default_locale
        else
          (@current_locale ||= RefinerySetting.find_or_set(:i18n_translation_current_locale,
            ::Refinery::I18n.default_locale, {
            :scoping => 'refinery',
            :callback_proc_as_string => %q{::Refinery::I18n.setup!}
          })).to_sym
        end
      end

      def current_locale=(locale)
        @current_locale = locale.to_sym
        value = {
          :value => locale.to_sym,
          :scoping => 'refinery',
          :callback_proc_as_string => %q{::Refinery::I18n.setup!}
        }
        # handles a change in Refinery API
        if RefinerySetting.methods.map(&:to_sym).include?(:set)
          RefinerySetting.set(:i18n_translation_current_locale, value)
        else
          RefinerySetting[:i18n_translation_current_locale] = value
        end

        ::I18n.locale = @current_locale
      end

      def default_locale
        (@default_locale ||= RefinerySetting.find_or_set(:i18n_translation_default_locale,
          :en, {
          :callback_proc_as_string => %q{::Refinery::I18n.setup!},
          :scoping => 'refinery'
        })).to_sym
      end

      def default_frontend_locale
        (@default_frontend_locale ||= RefinerySetting.find_or_set(:i18n_translation_default_frontend_locale,
          :en, {
          :scoping => 'refinery',
          :callback_proc_as_string => %q{::Refinery::I18n.setup!}
        })).to_sym
      end

      def frontend_locales
        @frontend_locales ||= RefinerySetting.find_or_set(:i18n_translation_frontend_locales,
          [self.default_frontend_locale], {
          :scoping => 'refinery',
          :callback_proc_as_string => %q{::Refinery::I18n.setup!}
        })
      end

      def locales
        @locales ||= RefinerySetting.find_or_set(:i18n_translation_locales, self.built_in_locales,
          {
            :scoping => 'refinery',
            :callback_proc_as_string => %q{::Refinery::I18n.setup!}
          }
        )
      end

      def has_locale?(locale)
        locales.has_key?(locale.try(:to_sym))
      end

      def setup!
        # Re-initialize variables.
        @enabled = nil
        @locales = nil
        @default_locale = nil
        @default_frontend_locale = nil
        @current_locale = nil
        @frontend_locales = nil

        self.load_base_locales!
        self.load_refinery_locales!
        self.load_app_locales!
        self.set_default_locale!
        self.ensure_locales_up_to_date!
      end

      def ensure_locales_up_to_date!
        # ensure running latest locales (this is awfully brittle).
        locales = if Refinery.version >= '0.9.9'
          RefinerySetting.get(:i18n_translation_locales, :scoping => 'refinery')
        else
          RefinerySetting.find_by_name_and_scoping('i18n_translation_locales', 'refinery').try(:value)
        end

        if locales.present? and locales.is_a?(Hash) and locales.keys.exclude?(self.built_in_locales.keys.last)
          value = {:value => locales.dup.deep_merge(self.built_in_locales), :scoping => 'refinery'}
          if RefinerySetting.respond_to?(:set)
            RefinerySetting.set(:i18n_translation_locales, value)
          else
            RefinerySetting[:i18n_translation_locales] = value
          end
        end
      end

      def load_base_locales!
        load_locales Pathname.new(__FILE__).parent.join "..", "config", "locales", "*.yml"
      end

      def load_refinery_locales!
        load_locales Refinery.root.join "vendor", "engines", "*", "config", "locales", "*.yml"
      end

      def load_app_locales!
        load_locales Rails.root.join "config", "locales", "*.yml"
      end

      def set_default_locale!
        ::I18n.default_locale = ::Refinery::I18n.default_locale
      end

      def load_locales(locale_files)
        locale_files = locale_files.to_s if locale_files.is_a? Pathname
        locale_files = Dir[locale_files] if locale_files.is_a? String
        locale_files.each do |locale_file|
          ::I18n.load_path.unshift locale_file
        end
      end

    end

    @built_in_locales = {
      :en => 'English',
      :fr => 'Français',
      :nl => 'Nederlands',
      :'pt-BR' => 'Português',
      :da => 'Dansk',
      :nb => 'Norsk Bokmål',
      :sl => 'Slovenian',
      :es => 'Español',
      :it => 'Italiano',
      :de => 'Deutsch',
      :lv => 'Latviski',
      :ru => 'Русский',
      :sv => 'Svenska',
      :pl => 'Polski',
      :'zh-CN' => 'Simple Chinese',
      :'zh-TW' => 'Traditional Chinese'
    }
  end
end
