# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten: rebranded for Klangten.

require "fileutils"
require "openssl"
require "securerandom"

module EltenMCP
  # MCP-specific naming and workspace policy around Klangten's shared package
  # format implementation. No package records or ZIP structures live here.
  class PackageBuilder
    def initialize(workspace)
      @workspace = workspace
    end

    def build(identifier, format = "eltenapp", certificate_path: nil, private_key_path: nil)
      entry, root = @workspace.source_entry(identifier)
      source = Programs.discover_source(entry.realpath)
      raise ToolError, "Cannot discover program source" if source == nil
      metadata = source[:manifest].raw.dup
      metadata["main"] = source[:main].to_s
      metadata_warnings = []
      metadata = Programs::ProgramPackageMetadata.prepare(
        metadata,
        :source_dir => root,
        :warning => proc { |message| metadata_warnings << message.to_s }
      )
      format = format.to_s.downcase
      raise InvalidParamsError, "format must be eltenapp or eltsetup" if !%w[eltenapp eltsetup].include?(format)
      output_dir = @workspace.data_path("builds")
      FileUtils.mkdir_p(output_dir)
      base = entry.realpath.to_s.sub(/\.eltenapp\z/i, "").gsub(/[^a-zA-Z0-9_.-]/, "_")
      output = EltenPath.join(output_dir, "#{base}-#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}-#{SecureRandom.hex(3)}.#{format}")
      signing = signing_credentials(certificate_path, private_key_path)
      build_output = signing == nil ? output : "#{output}.unsigned-#{SecureRandom.hex(6)}"
      values = Programs::UnsignedPackageBuilder.build(:source_dir => root, :output => build_output,
        :format => format, :metadata => metadata)
      certificate = signing == nil ? nil : sign_package(build_output, output, format, signing)
      values = {
        "program" => entry.realpath, "format" => values["format"], "path" => values["path"],
        "size" => values["size"], "signed" => false, "builder_profile" => values["builder_profile"],
        "metadata_warnings" => metadata_warnings,
        "warning" => "Unsigned developer build. Programs declaring gems are rejected; use Klangten's full setup builder when additional gems must be bundled."
      }
      if certificate != nil
        values["path"] = output
        values["size"] = File.size(output).to_i
        values["signed"] = true
        values["builder_profile"] = "externally_signed_without_declared_gems"
        values["certificate"] = certificate
        values["warning"] = "The embedded eltenapp signature was verified against this Klangten client's trust root. Keep the private key outside program sources and MCP output."
      end
      values
    rescue Programs::ProgramError => e
      raise ToolError, e.message
    rescue OpenSSL::OpenSSLError => e
      raise ToolError, "Cannot sign program package: #{e.message}"
    ensure
      File.delete(build_output) if defined?(build_output) && build_output != output && File.file?(build_output)
    end

    private

    def signing_credentials(certificate_path, private_key_path)
      requested = certificate_path.to_s != "" || private_key_path.to_s != ""
      return nil if !requested
      raise InvalidParamsError, "Both certificate_path and private_key_path are required for signing" if certificate_path.to_s == "" || private_key_path.to_s == ""

      certificate_file = File.expand_path(certificate_path.to_s)
      key_file = File.expand_path(private_key_path.to_s)
      raise ToolError, "Signing certificate not found" if !File.file?(certificate_file)
      raise ToolError, "Signing private key not found" if !File.file?(key_file)
      certificate = OpenSSL::X509::Certificate.new(File.binread(certificate_file))
      private_key = OpenSSL::PKey.read(File.binread(key_file))
      raise ToolError, "The supplied private key does not match the signing certificate" if !certificate.check_private_key(private_key)

      { :certificate_path => certificate_file, :private_key_path => key_file }
    end

    def sign_package(unsigned, output, format, signing)
      if format == "eltenapp"
        signed, verification = sign_payload(File.binread(unsigned), signing)
        File.binwrite(output, signed)
        verification
      else
        sign_setup(unsigned, output, signing)
      end
    rescue Exception
      File.delete(output) if File.file?(output)
      raise
    end

    def sign_setup(unsigned, output, signing)
      verification = nil
      writer = Programs::UnsignedPackageBuilder::ZipWriter.new(output)
      Programs.open_zip(unsigned) do |zip|
        Programs.zip_entries(zip).each do |entry|
          next if Programs.zip_directory_entry?(entry)
          name = Programs.safe_zip_entry_name(entry)
          data = Programs.zip_read(entry)
          if File.extname(name).downcase == ".eltenapp"
            raise ToolError, "Setup package contains more than one eltenapp payload" if verification != nil
            data, verification = sign_payload(data, signing)
          end
          mtime = entry.respond_to?(:time) ? entry.time : Time.now
          writer.add(name, data, mtime)
        end
      end
      raise ToolError, "Setup package contains no eltenapp payload" if verification == nil
      writer.close
      verification
    ensure
      writer.close if writer != nil
    end

    def sign_payload(payload, signing)
      signed = Programs::ProgramSigning.sign_code_file(
        payload,
        :certificate_path => signing[:certificate_path],
        :private_key_path => signing[:private_key_path]
      )
      decoded = Programs::ProgramSigning.decode_package(signed, :source => "MCP build")
      verification = Programs::ProgramSigning.verify_decoded!(decoded, :source => "MCP build")
      [
        signed,
        {
          "subject" => verification[:subject].to_s,
          "sha256_fingerprint" => verification[:fingerprint].to_s,
          "trusted_root_sha256" => verification[:root].to_s,
          "trusted_by_current_elten" => true
        }
      ]
    rescue Programs::ProgramSigning::SignatureError => e
      raise ToolError, "The signed package would not be accepted by this Klangten client: #{e.message}"
    end
  end
end
