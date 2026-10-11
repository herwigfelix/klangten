# Klangten tasks. `rake test` runs the test suite (docs/testing.md).

desc "Run the Klangten test suite (TEST=path/to/test_file.rb for one file)"
task :test do
  args = ENV["TEST"] ? [ENV["TEST"]] : []
  ruby File.join(__dir__, "test", "run.rb"), *args
end

task default: :test
