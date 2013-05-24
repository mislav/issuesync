require 'rbconfig'
ruby = File.join(RbConfig::CONFIG['bindir'], RbConfig::CONFIG['ruby_install_name'])
here = File.expand_path('..', __FILE__)

check_prefix = lambda { |dir|
  bindir = File.join(dir, 'bin')
  File.directory?(bindir) && File.writable?(bindir)
}

desc "Install `issuesync' to $PREFIX/bin (default: ~/bin, /usr/local/bin)"
task :install do
  abort "Ruby 1.9 required" if RUBY_VERSION < '1.9'

  prefix = ENV['prefix'] || ENV['PREFIX']
  dir = prefix || ENV['HOME']

  unless check_prefix.call(dir)
    dir = '/usr/local' if !prefix && dir == ENV['HOME']
    unless check_prefix.call(dir)
      abort "error: `#{dir}/bin' is not writable"
    end
  end

  exefile = File.join(dir, 'bin/issuesync')
  if File.exist?(exefile)
    abort "aborted: `#{exefile}' already exists"
  end

  File.open(exefile, 'w', 755) do |exe|
    exe.puts "#!/bin/sh"
    exe.puts "'#{ruby}' '#{here}/issuesync.rb'"
  end

  puts "installed #{exefile}"
end
