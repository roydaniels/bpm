require 'thor'
require 'highline'

module BPM
  module CLI
    LOGIN_MESSAGE = "Please login first with `bpm login`."

    class Base < Thor

      class_option :verbose, :type => :boolean, :default => false,
        :aliases => ['-V'],
        :desc => 'Show additional debug information while running'

      desc "owner", "Manage users for a package"
      subcommand "owner", BPM::CLI::Owner

      desc "fetch [PACKAGE]", "Fetch one or many bpm packages to local cache"
      method_option :version,    :type => :string,  :default => ">= 0", :aliases => ['-v'],    :desc => 'Specify a version to install'
      method_option :prerelease, :type => :boolean, :default => false,  :aliases => ['--pre'], :desc => 'Install a prerelease version'
      def fetch(*packages)
        project = BPM::Project.nearest_project(Dir.pwd) if packages.size==0
        if project
          success = project.fetch_dependencies options[:verbose]
          if !success
            abort project.errors * "\n"
          else
            say "Fetched dependent packages for #{project.name}"
          end
          
        else
          report_arity_error("fetch") and return if packages.size.zero?

          begin
            packages.each do |package|
              installed = BPM::Remote.new.install(package, options[:version], options[:prerelease])
              installed.each do |spec|
                say "Successfully fetched #{spec.name} (#{spec.version})"
              end
            end
          rescue LibGems::InstallError => e
            abort "Fetch error: #{e}"
          rescue LibGems::GemNotFoundException => e
            abort "Can't find package #{e.name} #{e.version} available for fetch"
          rescue Errno::EACCES, LibGems::FilePermissionError => e
            abort e.message
          end
        end
      end
      

      desc "fetched [PACKAGE]", "Shows what bpm packages are fetched"
      def fetched(*packages)
        local = BPM::Local.new
        index = local.installed(packages)
        print_specs(packages, index)
      end

      # TODO: Options for versions and prerelease
      desc "add [PACKAGE]", "Add package to project"
      def add(name)
        dep = LibGems::Dependency.new(name, LibGems::Requirement.default)
        installed = LibGems.source_index.search(dep)
        package = if installed.empty?
          say "Installing from remote"
          installed = BPM::Remote.new.install(name, '>= 0', false)
          installed.find{|i| i.name == name }
        else
          installed.inject{|newest,current| newest.version > current.version ? newest : current }
        end
        if package
          say "Added #{package.name} (#{package.version})"
        else
          say "Unable to find package to add"
        end
      end

      desc "login", "Log in with your BPM credentials"
      def login
        highline = HighLine.new
        say "Enter your BPM credentials."

        begin
          email = highline.ask "\nEmail:" do |q|
            next unless STDIN.tty?
            q.readline = true
          end

          password = highline.ask "\nPassword:" do |q|
            next unless STDIN.tty?
            q.echo = "*"
          end
        rescue Interrupt => ex
          abort "Cancelled login."
        end

        say "\nLogging in as #{email}..."

        if BPM::Remote.new.login(email, password)
          say "Logged in!"
        else
          say "Incorrect email or password."
          login
        end
      end

      desc "push", "Distribute your bpm package"
      def push(package)
        remote = BPM::Remote.new
        if remote.logged_in?
          say remote.push(package)
        else
          say LOGIN_MESSAGE
        end
      end

      desc "yank", "Remove a specific package version release from SproutCutter"
      method_option :version, :type => :string,  :default => nil,   :aliases => ['-v'],    :desc => 'Specify a version to yank'
      method_option :undo,    :type => :boolean, :default => false,                        :desc => 'Unyank package'
      def yank(package)
        if options[:version]
          remote = BPM::Remote.new
          if remote.logged_in?
            if options[:undo]
              say remote.unyank(package, options[:version])
            else
              say remote.yank(package, options[:version])
            end
          else
            say LOGIN_MESSAGE
          end
        else
          say "Version required"
        end
      end

      desc "list", "View available packages for download"
      method_option :all,        :type => :boolean, :default => false, :aliases => ['-a'],    :desc => 'List all versions available'
      method_option :prerelease, :type => :boolean, :default => false, :aliases => ['--pre'], :desc => 'List prerelease versions available'
      def list(*packages)
        remote = BPM::Remote.new
        index  = remote.list_packages(packages, options[:all], options[:prerelease])
        print_specs(packages, index)
      end

      desc "new [NAME]", "Generate a new project skeleton"
      def new(name)
        path = File.expand_path name
        ProjectGenerator.new(self, name, path).run
        init(path)
      end

      desc "init [PATHS]", "Configure a project to use bpm for management"
      def init(*paths)
        paths = [Dir.pwd] if paths.size.zero?
        paths.each do |path|
          InitGenerator.new(self, path, path).run
        end
      end
      
      desc "compile [PATH]", "Build the bpm_package for development"
      method_option :mode, :type => :string, :default => :debug, :aliases => ['-m'], :desc => 'Set build mode for compile (default debug)'
      def compile(path=nil)
        project = Project.nearest_project self, (path || Dir.pwd)
        if project.nil?
          if path.nil?
            abort "You do not appear to be in a valid bpm project.  Maybe you are in the wrong working directory?"
          else
            abort "No bpm project could be found at #{File.expand_path path}"
          end
        else
          project.compile(options[:mode], options[:verbose])
        end
      end

      desc "build", "Build a bpm package from a package.json"
      def build
        local = BPM::Local.new
        if local.logged_in?
          package = local.pack("package.json")
          if package.errors.empty?
            puts "Successfully built package: #{package.to_ext}"
          else
            failure_message = "BPM encountered the following problems building your package:"
            package.errors.each do |error|
              failure_message << "\n* #{error}"
            end
            abort failure_message
          end
        else
          abort LOGIN_MESSAGE
        end
      end

      desc "unpack [PACKAGE]", "Extract files from a bpm package"
      method_option :target, :type => :string, :default => ".", :aliases => ['-t'], :desc => 'Unpack to given directory'
      def unpack(*paths)
        local = BPM::Local.new

        paths.each do |path|
          begin
            package     = local.unpack(path, options[:target])
            unpack_path = File.expand_path(File.join(Dir.pwd, options[:target], package.to_full_name))
            puts "Unpacked package into: #{unpack_path}"
          rescue Errno::EACCES, LibGems::FilePermissionError => ex
            abort "There was a problem unpacking #{path}:\n#{ex.message}"
          end
        end
      end

      private

        def report_arity_error(name)
          self.class.handle_argument_error(self.class.tasks[name], nil)
        end

        def print_specs(names, index)
          packages = {}

          index.each do |(name, version, platform)|
            packages[name] ||= []
            packages[name] << version
          end

          if packages.size.zero?
            abort %{No packages found matching "#{names.join('", "')}".}
          else
            packages.each do |name, versions|
              puts "#{name} (#{versions.sort.reverse.join(", ")})"
            end
          end
        end

    end
  end
end
