class Vibeutils < Formula
  desc "Modern Unix utilities with colors, icons, and progress bars"
  homepage "https://github.com/kelp/vibeutils"
  url "https://github.com/kelp/vibeutils/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "PLACEHOLDER_SHA256"
  license "MIT"
  head "https://github.com/kelp/vibeutils.git", branch: "main"

  depends_on "zig" => :build

  option "with-default-names", "Install commands without 'v' prefix (not recommended)"

  def install
    # Build the project
    system "zig", "build", "-Doptimize=ReleaseSafe"

    # Install binaries
    if build.with? "default-names"
      # Install without prefix - warn user!
      opoo "Installing without prefix will shadow system utilities!"
      bin.install Dir["zig-out/bin/*"]
    else
      # Install with 'v' prefix
      Dir["zig-out/bin/*"].each do |file|
        base_name = File.basename(file)
        bin.install file => "v#{base_name}"
      end

      # Create vibebin directory with unprefixed symlinks
      (libexec/"vibebin").mkpath
      Dir["zig-out/bin/*"].each do |file|
        base_name = File.basename(file)
        (libexec/"vibebin"/base_name).make_symlink(bin/"v#{base_name}")
      end

      # Create activation script
      (libexec/"activate.sh").write <<~EOS
        #!/bin/bash
        # vibeutils activation script for Homebrew installation

        if [[ -z "$VIBEUTILS_ORIGINAL_PATH" ]]; then
            export VIBEUTILS_ORIGINAL_PATH="$PATH"
            export PATH="#{libexec}/vibebin:$PATH"
            echo "vibeutils activated! Commands are now available without prefix."
            echo "Run 'deactivate-vibeutils' to restore original behavior."
            
            # Define deactivation function
            deactivate-vibeutils() {
                if [[ -n "$VIBEUTILS_ORIGINAL_PATH" ]]; then
                    export PATH="$VIBEUTILS_ORIGINAL_PATH"
                    unset VIBEUTILS_ORIGINAL_PATH
                    unset -f deactivate-vibeutils
                    echo "vibeutils deactivated. Original PATH restored."
                else
                    echo "vibeutils is not currently activated."
                fi
            }
        else
            echo "vibeutils is already activated."
        fi
      EOS
      (libexec/"activate.sh").chmod 0755
    end

    # Install man pages
    man1.install Dir["man/man1/*"] if Dir.exist?("man/man1")

    # Install completions if they exist
    if Dir.exist?("completions")
      bash_completion.install Dir["completions/bash/*"] if Dir.exist?("completions/bash")
      zsh_completion.install Dir["completions/zsh/*"] if Dir.exist?("completions/zsh")
      fish_completion.install Dir["completions/fish/*"] if Dir.exist?("completions/fish")
    end
  end

  def caveats
    if build.with? "default-names"
      <<~EOS
        WARNING: vibeutils has been installed without a command prefix.
        This shadows the system utilities. To uninstall and restore system
        utilities, run:
          brew uninstall vibeutils

      EOS
    else
      <<~EOS
        vibeutils has been installed with 'v' prefix.
        Commands are available as: vls, vcp, vmv, vrm, vmkdir, vtouch, etc.

        To use vibeutils commands by default, you can either:

        1. Add the vibebin directory to your PATH:
             export PATH="#{opt_libexec}/vibebin:$PATH"

        2. Source the activation script (for temporary activation):
             source #{opt_libexec}/activate.sh

        3. Create shell aliases in your profile:
             alias ls='vls'
             alias cp='vcp'
             alias mv='vmv'
             # ... etc

      EOS
    end
  end

  test do
    # Test that the binaries work
    if build.with? "default-names"
      assert_match "vibeutils", shell_output("#{bin}/echo vibeutils")
    else
      assert_match "vibeutils", shell_output("#{bin}/vecho vibeutils")
    end
  end
end