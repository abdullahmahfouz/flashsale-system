source "https://rubygems.org"

ruby File.read(File.expand_path(".ruby-version", __dir__)).strip.delete_prefix("ruby-")

gem "rails", "~> 8.1.4"
gem "mysql2", "~> 0.5"
gem "puma", ">= 5.0"
gem "redis", "~> 5.0"
gem "sidekiq", "~> 8.0"
gem "sorbet-runtime"
gem "packwerk"
gem "tzinfo-data", platforms: %i[ windows jruby ]
gem "bootsnap", require: false

group :development, :test do
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"
  gem "sorbet", require: false
  gem "tapioca", require: false
  gem "rubocop-rails-omakase", require: false
end
