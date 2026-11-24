source 'https://rubygems.org'
# Local build only. GitHub Pages (legacy build) ignores this file and uses its own pinned gems.
# The github-pages gem is not used: its jekyll-remote-theme pins rubyzip < 3.0 (Dependabot #42).
gem 'jekyll', '~> 3.10'
gem 'kramdown-parser-gfm'
gem 'webrick'
gem 'base64'      # not default gems from Ruby 3.4
gem 'bigdecimal'
gem 'logger'
gem 'wdm', '>= 0.1.1' if Gem.win_platform?
gem 'tzinfo-data', platforms: [:mingw, :mswin, :x64_mingw, :jruby]
group :jekyll_plugins do
  gem "jekyll-feed"
  gem "jekyll-github-metadata"
end
gem 'rake'

#theme
gem 'jekyll-theme-cayman'
gem 'jekyll-swiss'
