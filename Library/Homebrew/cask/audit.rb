# frozen_string_literal: true

require "cask/checkable"
require "cask/download"
require "digest"
require "utils/curl"
require "utils/git"

module Cask
  class Audit
    include Checkable
    extend Predicable

    attr_reader :cask, :commit_range, :download

    attr_predicate :check_appcast?

    def initialize(cask, check_appcast: false, download: false, check_token_conflicts: false,
                   commit_range: nil, command: SystemCommand)
      @cask = cask
      @check_appcast = check_appcast
      @download = download
      @commit_range = commit_range
      @check_token_conflicts = check_token_conflicts
      @command = command
    end

    def check_token_conflicts?
      @check_token_conflicts
    end

    def run!
      check_required_stanzas
      check_version
      check_sha256
      check_url
      check_generic_artifacts
      check_token_conflicts
      check_download
      check_https_availability
      check_single_pre_postflight
      check_single_uninstall_zap
      check_untrusted_pkg
      check_hosting_with_appcast
      check_latest_with_appcast
      check_latest_with_auto_updates
      check_stanza_requires_uninstall
      check_appcast_contains_version
      self
    rescue => e
      odebug "#{e.message}\n#{e.backtrace.join("\n")}"
      add_error "exception while auditing #{cask}: #{e.message}"
      self
    end

    def success?
      !(errors? || warnings?)
    end

    def summary_header
      "audit for #{cask}"
    end

    private

    def check_untrusted_pkg
      odebug "Auditing pkg stanza: allow_untrusted"

      return if @cask.sourcefile_path.nil?

      tap = @cask.tap
      return if tap.nil?
      return if tap.user != "Homebrew"

      return unless cask.artifacts.any? { |k| k.is_a?(Artifact::Pkg) && k.stanza_options.key?(:allow_untrusted) }

      add_warning "allow_untrusted is not permitted in official Homebrew Cask taps"
    end

    def check_stanza_requires_uninstall
      odebug "Auditing stanzas which require an uninstall"

      return if cask.artifacts.none? { |k| k.is_a?(Artifact::Pkg) || k.is_a?(Artifact::Installer) }
      return if cask.artifacts.any? { |k| k.is_a?(Artifact::Uninstall) }

      add_warning "installer and pkg stanzas require an uninstall stanza"
    end

    def check_single_pre_postflight
      odebug "Auditing preflight and postflight stanzas"

      if cask.artifacts.count { |k| k.is_a?(Artifact::PreflightBlock) && k.directives.key?(:preflight) } > 1
        add_warning "only a single preflight stanza is allowed"
      end

      count = cask.artifacts.count do |k|
        k.is_a?(Artifact::PostflightBlock) &&
          k.directives.key?(:postflight)
      end
      return unless count > 1

      add_warning "only a single postflight stanza is allowed"
    end

    def check_single_uninstall_zap
      odebug "Auditing single uninstall_* and zap stanzas"

      if cask.artifacts.count { |k| k.is_a?(Artifact::Uninstall) } > 1
        add_warning "only a single uninstall stanza is allowed"
      end

      count = cask.artifacts.count do |k|
        k.is_a?(Artifact::PreflightBlock) &&
          k.directives.key?(:uninstall_preflight)
      end

      add_warning "only a single uninstall_preflight stanza is allowed" if count > 1

      count = cask.artifacts.count do |k|
        k.is_a?(Artifact::PostflightBlock) &&
          k.directives.key?(:uninstall_postflight)
      end

      add_warning "only a single uninstall_postflight stanza is allowed" if count > 1

      return unless cask.artifacts.count { |k| k.is_a?(Artifact::Zap) } > 1

      add_warning "only a single zap stanza is allowed"
    end

    def check_required_stanzas
      odebug "Auditing required stanzas"
      [:version, :sha256, :url, :homepage].each do |sym|
        add_error "a #{sym} stanza is required" unless cask.send(sym)
      end
      add_error "at least one name stanza is required" if cask.name.empty?
      # TODO: specific DSL knowledge should not be spread around in various files like this
      installable_artifacts = cask.artifacts.reject { |k| [:uninstall, :zap].include?(k) }
      add_error "at least one activatable artifact stanza is required" if installable_artifacts.empty?
    end

    def check_version
      return unless cask.version

      check_no_string_version_latest
      check_no_file_separator_in_version
    end

    def check_no_string_version_latest
      odebug "Verifying version :latest does not appear as a string ('latest')"
      return unless cask.version.raw_version == "latest"

      add_error "you should use version :latest instead of version 'latest'"
    end

    def check_no_file_separator_in_version
      odebug "Verifying version does not contain '#{File::SEPARATOR}'"
      return unless cask.version.raw_version.is_a?(String)
      return unless cask.version.raw_version.include?(File::SEPARATOR)

      add_error "version should not contain '#{File::SEPARATOR}'"
    end

    def check_sha256
      return unless cask.sha256

      check_sha256_no_check_if_latest
      check_sha256_actually_256
      check_sha256_invalid
    end

    def check_sha256_no_check_if_latest
      odebug "Verifying sha256 :no_check with version :latest"
      return unless cask.version.latest?
      return if cask.sha256 == :no_check

      add_error "you should use sha256 :no_check when version is :latest"
    end

    def check_sha256_actually_256(sha256: cask.sha256, stanza: "sha256")
      odebug "Verifying #{stanza} string is a legal SHA-256 digest"
      return unless sha256.is_a?(String)
      return if sha256.length == 64 && sha256[/^[0-9a-f]+$/i]

      add_error "#{stanza} string must be of 64 hexadecimal characters"
    end

    def check_sha256_invalid(sha256: cask.sha256, stanza: "sha256")
      odebug "Verifying #{stanza} is not a known invalid value"
      empty_sha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
      return unless sha256 == empty_sha256

      add_error "cannot use the sha256 for an empty string in #{stanza}: #{empty_sha256}"
    end

    def check_latest_with_appcast
      return unless cask.version.latest?
      return unless cask.appcast

      add_warning "Casks with an appcast should not use version :latest"
    end

    def check_latest_with_auto_updates
      return unless cask.version.latest?
      return unless cask.auto_updates

      add_warning "Casks with `version :latest` should not use `auto_updates`"
    end

    def check_hosting_with_appcast
      return if cask.appcast

      add_appcast = "please add an appcast. See https://github.com/Homebrew/homebrew-cask/blob/master/doc/cask_language_reference/stanzas/appcast.md"

      case cask.url.to_s
      when %r{github.com/([^/]+)/([^/]+)/releases/download/(\S+)}
        return if cask.version.latest?

        add_warning "Download uses GitHub releases, #{add_appcast}"
      when %r{sourceforge.net/(\S+)}
        return if cask.version.latest?

        add_warning "Download is hosted on SourceForge, #{add_appcast}"
      when %r{dl.devmate.com/(\S+)}
        add_warning "Download is hosted on DevMate, #{add_appcast}"
      when %r{rink.hockeyapp.net/(\S+)}
        add_warning "Download is hosted on HockeyApp, #{add_appcast}"
      end
    end

    def check_url
      return unless cask.url

      check_download_url_format
    end

    def check_download_url_format
      odebug "Auditing URL format"
      if bad_sourceforge_url?
        add_warning "SourceForge URL format incorrect. See https://github.com/Homebrew/homebrew-cask/blob/master/doc/cask_language_reference/stanzas/url.md#sourceforgeosdn-urls"
      elsif bad_osdn_url?
        add_warning "OSDN URL format incorrect. See https://github.com/Homebrew/homebrew-cask/blob/master/doc/cask_language_reference/stanzas/url.md#sourceforgeosdn-urls"
      end
    end

    def bad_url_format?(regex, valid_formats_array)
      return false unless cask.url.to_s =~ regex

      valid_formats_array.none? { |format| cask.url.to_s =~ format }
    end

    def bad_sourceforge_url?
      bad_url_format?(/sourceforge/,
                      [
                        %r{\Ahttps://sourceforge\.net/projects/[^/]+/files/latest/download\Z},
                        %r{\Ahttps://downloads\.sourceforge\.net/(?!(project|sourceforge)\/)},
                      ])
    end

    def bad_osdn_url?
      bad_url_format?(/osd/, [%r{\Ahttps?://([^/]+.)?dl\.osdn\.jp/}])
    end

    def check_generic_artifacts
      cask.artifacts.select { |a| a.is_a?(Artifact::Artifact) }.each do |artifact|
        unless artifact.target.absolute?
          add_error "target must be absolute path for #{artifact.class.english_name} #{artifact.source}"
        end
      end
    end

    def check_token_conflicts
      return unless check_token_conflicts?
      return unless core_formula_names.include?(cask.token)

      add_warning "possible duplicate, cask token conflicts with Homebrew core formula: #{core_formula_url}"
    end

    def core_tap
      @core_tap ||= CoreTap.instance
    end

    def core_formula_names
      core_tap.formula_names
    end

    def core_formula_url
      "#{core_tap.default_remote}/blob/master/Formula/#{cask.token}.rb"
    end

    def check_download
      return unless download && cask.url

      odebug "Auditing download"
      downloaded_path = download.perform
      Verify.all(cask, downloaded_path)
    rescue => e
      add_error "download not possible: #{e.message}"
    end

    def check_appcast_contains_version
      return unless check_appcast?
      return if cask.appcast.to_s.empty?
      return if cask.appcast.configuration == :no_check

      appcast_stanza = cask.appcast.to_s
      appcast_contents, = curl_output("--compressed", "--user-agent", HOMEBREW_USER_AGENT_FAKE_SAFARI, "--location",
                                      "--max-time", "5", appcast_stanza)
      version_stanza = cask.version.to_s
      if cask.appcast.configuration.blank?
        adjusted_version_stanza = version_stanza.split(",")[0].split("-")[0].split("_")[0]
      else
        adjusted_version_stanza = cask.appcast.configuration
      end
      return if appcast_contents.include? adjusted_version_stanza

      add_warning "appcast at URL '#{appcast_stanza}' does not contain"\
                  " the version number: '#{adjusted_version_stanza}'"
    rescue
      add_error "appcast at URL '#{appcast_stanza}' offline or looping"
    end

    def check_https_availability
      return unless download

      if !cask.url.blank? && !cask.url.using
        check_url_for_https_availability(cask.url, user_agents: [cask.url.user_agent])
      end
      check_url_for_https_availability(cask.appcast) unless cask.appcast.blank?
      check_url_for_https_availability(cask.homepage, user_agents: [:browser]) unless cask.homepage.blank?
    end

    def check_url_for_https_availability(url_to_check, user_agents: [:default])
      problem = curl_check_http_content(url_to_check.to_s, user_agents: user_agents)
      add_error problem if problem
    end
  end
end
