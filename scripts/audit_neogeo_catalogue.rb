#!/usr/bin/env ruby
# frozen_string_literal: true

# Compare local Neo Geo entries with SNK's official NEOGEO MUSEUM catalogue.
# This script is intentionally read-only: unmatched rows are review candidates,
# not proof that a game was unreleased.
#
# Usage:
#   ruby scripts/audit_neogeo_catalogue.rb
#   ruby scripts/audit_neogeo_catalogue.rb --html tmp/neogeo-catalogue.html
#   ruby scripts/audit_neogeo_catalogue.rb --output reports/neogeo-catalogue-audit.tsv

require 'cgi'
require 'csv'
require 'date'
require 'fileutils'
require 'json'
require 'net/http'
require 'optparse'
require 'uri'

ROOT = File.expand_path('..', __dir__)
CATALOGUE_URL = 'https://neogeomuseum.snk-corp.co.jp/catalogue/index.php'
DEFAULT_OUTPUT = File.join(ROOT, 'reports', 'neogeo-catalogue-audit.tsv')
ALIASES_PATH = File.join(ROOT, 'data', 'imports', 'neogeo_snk_catalogue_aliases.csv')

def plain_text(html)
  text = html.gsub(/<br\s*\/?\s*>/i, "\n").gsub(/<[^>]+>/, '').gsub('&nbsp;', ' ')
  2.times { text = CGI.unescapeHTML(text) }
  text.strip
end

def catalogue_rows(html)
  html.scan(/<tr(?:\s[^>]*)?>(.*?)<\/tr>/mi).filter_map do |row_match|
    cells = row_match.first.scan(/<td\s+class="(?:title|genre|maker|date)"[^>]*>(.*?)<\/td>/mi)
    next unless cells.length == 4

    title, genre, maker, releases = cells.flatten.map { |cell| plain_text(cell) }
    {
      title: title.gsub(/\s+/, ' ').strip,
      genre: genre,
      maker: maker,
      releases: releases.lines.map(&:strip).reject(&:empty?).join(' | ')
    }
  end
end

def normalized_title(text)
  text.unicode_normalize(:nfkc).downcase.gsub(/[^\p{Letter}\p{Number}]/, '')
end

def first_release_date(releases)
  dates = releases.scan(/(\d{4})(?:\/(\d{2})(?:\/(\d{2}))?)?/).map do |year, month, day|
    [Date.new(year.to_i, (month || '1').to_i, (day || '1').to_i), [year, month, day].compact.join('-')]
  end
  dates.min_by(&:first)&.last
end

def similarity(left, right)
  left_chars = normalized_title(left).chars
  right_chars = normalized_title(right).chars
  return 1.0 if left_chars == right_chars
  return 0.0 if left_chars.length < 2 || right_chars.length < 2

  left_pairs = left_chars.each_cons(2).map(&:join)
  right_pairs = right_chars.each_cons(2).map(&:join)
  overlap = left_pairs.tally.sum { |pair, count| [count, right_pairs.count(pair)].min }
  (2.0 * overlap) / (left_pairs.length + right_pairs.length)
end

def best_suggestion(titles, official)
  official.map do |entry|
    score = titles.map { |title| similarity(title, entry[:title]) }.max
    [score, entry]
  end.max_by(&:first)
end

def local_games
  Dir[File.join(ROOT, 'data', 'games', 'neogeo', '*.json')].sort.map do |path|
    game = JSON.parse(File.read(path))
    {
      id: game.fetch('id'),
      rom: Array(game['roms']).first&.fetch('name', nil),
      titles: Array(game['titles']).map { |title| title.fetch('text') }
    }
  end
end

def catalogue_aliases
  CSV.read(ALIASES_PATH, headers: true).to_h { |row| [row.fetch('rom'), row.fetch('official_title')] }
end

def fetch_catalogue
  uri = URI(CATALOGUE_URL)
  response = Net::HTTP.get_response(uri)
  abort "NEOGEO MUSEUM request failed: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

  response.body.force_encoding(Encoding::UTF_8)
end

def main
  options = { html: nil, output: DEFAULT_OUTPUT }
  OptionParser.new do |opts|
    opts.banner = 'Usage: ruby scripts/audit_neogeo_catalogue.rb [options]'
    opts.on('--html PATH', 'use a saved catalogue page instead of downloading') { |v| options[:html] = v }
    opts.on('--output PATH', 'write the TSV report to PATH') { |v| options[:output] = v }
  end.parse!

  html = options[:html] ? File.read(options[:html]) : fetch_catalogue
  official = catalogue_rows(html)
  abort 'No catalogue entries found; the upstream HTML may have changed' if official.empty?

  official_by_title = official.group_by { |row| normalized_title(row[:title]) }
  aliases = catalogue_aliases
  matched_official = {}
  rows = local_games.map do |game|
    matches = game[:titles].flat_map { |title| official_by_title.fetch(normalized_title(title), []) }.uniq
    alias_title = aliases[game[:rom]]
    alias_matches = alias_title ? official_by_title.fetch(normalized_title(alias_title), []) : []
    matches |= alias_matches
    matches.each { |match| matched_official[match.object_id] = true }
    match = matches.one? ? matches.first : nil
    suggestion_score, suggestion = best_suggestion(game[:titles], official)
    suggestion = nil if match || suggestion_score < 0.6
    status = if matches.one?
               alias_matches.empty? ? 'official_exact' : 'official_alias'
             elsif matches.empty?
               'review_local_only'
             else
               'review_ambiguous'
             end
    [status, game[:id], game[:rom], game[:titles].join(' | '), match&.dig(:title),
     match&.dig(:genre), match&.dig(:maker), match&.dig(:releases),
     match && first_release_date(match[:releases]),
     suggestion&.dig(:title), suggestion && format('%.3f', suggestion_score)]
  end

  official.each do |entry|
    next if matched_official[entry.object_id]

    rows << ['review_official_only', nil, nil, nil, entry[:title], entry[:genre], entry[:maker], entry[:releases],
             first_release_date(entry[:releases]), nil, nil]
  end

  FileUtils.mkdir_p(File.dirname(options[:output])) unless Dir.exist?(File.dirname(options[:output]))
  CSV.open(options[:output], 'w', col_sep: "\t") do |csv|
    csv << %w[status local_id rom local_titles official_title genre maker releases first_release_date
              suggested_title suggestion_score]
    rows.each { |row| csv << row }
  end

  counts = rows.each_with_object(Hash.new(0)) { |row, out| out[row.first] += 1 }
  puts "Official catalogue: #{official.length}"
  puts "Local games: #{local_games.length}"
  counts.sort.each { |status, count| puts "#{status}: #{count}" }
  puts "Report: #{options[:output]}"
end

main if __FILE__ == $PROGRAM_NAME
