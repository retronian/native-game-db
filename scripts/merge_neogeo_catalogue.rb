#!/usr/bin/env ruby
# frozen_string_literal: true

# Add missing Neo Geo release dates, publishers and genres from an SNK audit
# report and the curated FBNeo metadata CSV. Existing values are untouched.
#
# Usage:
#   ruby scripts/audit_neogeo_catalogue.rb
#   ruby scripts/merge_neogeo_catalogue.rb --dry-run
#   ruby scripts/merge_neogeo_catalogue.rb

require 'csv'
require 'json'
require 'optparse'
require_relative 'lib/script_detector'

ROOT = File.expand_path('..', __dir__)
DEFAULT_REPORT = File.join(ROOT, 'reports', 'neogeo-catalogue-audit.tsv')
FBNEO_METADATA = File.join(ROOT, 'data', 'imports', 'neogeo_fbneo_metadata.csv')

MAKERS = {
  'ADK' => %w[adk], 'NMK' => %w[nmk], 'SNK' => %w[snk],
  'SNKプレイモア' => %w[snk-playmore],
  'SNKプレイモア/悠紀エンタープライズ' => %w[snk-playmore yuki-enterprise],
  'アイキ' => %w[aiky], 'アトラス/ノイズファクトリー' => %w[atlus noise-factory],
  'ウェイブ' => %w[wave], 'エイコム' => %w[eicom], 'エイティング' => %w[eighting],
  'エヴォガエンターテイメント' => %w[evoga-entertainment], 'ガバキング' => %w[gavaking],
  'サミー工業' => %w[sammy], 'サンソフト' => %w[sunsoft], 'ザウルス' => %w[saurus],
  'タカラ' => %w[takara], 'テクノスジャパン' => %w[technos-japan],
  'データイースト' => %w[data-east], 'ナスカ' => %w[nazca], 'ハドソン' => %w[hudson-soft],
  'ビスコ' => %w[visco], 'ビッコム' => %w[viccom], 'ビデオシステム' => %w[video-system],
  'フェイス' => %w[face], 'モノリス' => %w[monolith], '夢工房' => %w[yumekobo], '彩京' => %w[psikyo]
}.freeze

GENRES = {
  '3Dアクション' => %w[action], '3Dレース' => %w[racing], 'アクション' => %w[action],
  'アクションシューティング' => %w[action shooter], 'クイズ' => %w[quiz],
  'コミカルアクション' => %w[action], 'シューティング' => %w[shooter], 'スポーツ' => %w[sports],
  'テーブル' => %w[tabletop], 'バラエティ' => %w[variety], 'パズル' => %w[puzzle],
  'ホラーアクション' => %w[action horror], 'リアルジョッキーアクション' => %w[sports],
  'レース' => %w[racing], '将棋' => %w[board-game], '格闘アクション' => %w[fighting],
  '格闘プロレス' => %w[wrestling], '横スクロールアクション' => %w[action],
  '横スクロールシューティング' => %w[shooter], '縦スクロールアクション' => %w[action],
  '縦スクロールシューティング' => %w[shooter], '麻雀' => %w[mahjong]
}.freeze

def parse_releases(text, source: 'snk')
  systems = { 'ＭＶＳカートリッジ' => 'mvs', 'ＮＥＯＧＥＯ ＲＯＭ' => 'aes', 'ＮＥＯＧＥＯ ＣＤ' => 'neogeo_cd' }
  text.split(' | ').filter_map do |release|
    label, date = release.split('：', 2).map(&:strip)
    label = label.gsub(/[[:space:]]+/, ' ').strip
    system = systems[label]
    normalized_date = date&.match(/\A\d{4}(?:\/\d{2}(?:\/\d{2})?)?\z/)&.to_s&.tr('/', '-')
    next unless system && normalized_date

    { 'system' => system, 'date' => normalized_date, 'region' => 'jp', 'source' => source }
  end
end

def add_metadata(game, date, publishers, genres, releases)
  game.each_with_object({}) do |(key, value), output|
    if key == 'releases'
      output[key] = Array(value) | releases
      next
    end
    output[key] = value
    next unless key == 'category'

    output['first_release_date'] = date unless game['first_release_date']
    output['publishers'] = publishers unless game['publishers']
    output['genres'] = genres unless game['genres']
    output['releases'] = releases unless game['releases']
  end
end

def normalized_title(text)
  text.unicode_normalize(:nfkc).downcase.gsub(/[^\p{Letter}\p{Number}]/, '')
end

def merge_snk_title(game, official_title)
  return false unless official_title

  matches = game.fetch('titles').select { |title| normalized_title(title.fetch('text')) == normalized_title(official_title) }
  if matches.any?
    title = matches.find { |candidate| candidate['region'] == 'jp' || candidate['lang'] == 'ja' } || matches.first
    return false if title['source'] == 'snk' && title['verified'] == true

    title['source'] = 'snk'
    title['verified'] = true
  else
    game.fetch('titles') << {
      'text' => official_title,
      'lang' => 'ja',
      'script' => ScriptDetector.detect(official_title),
      'region' => 'jp',
      'form' => 'official',
      'source' => 'snk',
      'verified' => true
    }
  end
  true
end

def main
  options = { report: DEFAULT_REPORT, dry_run: false }
  OptionParser.new do |opts|
    opts.banner = 'Usage: ruby scripts/merge_neogeo_catalogue.rb [options]'
    opts.on('--report PATH') { |v| options[:report] = v }
    opts.on('--dry-run') { options[:dry_run] = true }
  end.parse!

  rows = CSV.read(options[:report], headers: true, col_sep: "\t")
  candidates = rows.filter_map do |row|
    next unless %w[official_exact official_alias].include?(row['status'])
    next if row['first_release_date'].to_s.empty?

    maker = row.fetch('maker')
    genre = row.fetch('genre')
    abort "Unknown NEOGEO MUSEUM maker: #{maker}" unless MAKERS.key?(maker)
    abort "Unknown NEOGEO MUSEUM genre: #{genre}" unless GENRES.key?(genre)

    [row.fetch('local_id'), {
      date: row.fetch('first_release_date'), publishers: MAKERS.fetch(maker), genres: GENRES.fetch(genre),
      official_title: row.fetch('official_title'), releases: parse_releases(row.fetch('releases'))
    }]
  end.to_h

  games_by_rom = Dir[File.join(ROOT, 'data', 'games', 'neogeo', '*.json')].to_h do |path|
    game = JSON.parse(File.read(path))
    [Array(game['roms']).first&.fetch('name', nil), game.fetch('id')]
  end
  CSV.foreach(FBNEO_METADATA, headers: true) do |row|
    id = games_by_rom[row.fetch('rom')]
    abort "Neo Geo ROM not found: #{row.fetch('rom')}" unless id

    candidates[id] = {
      date: row.fetch('first_release_date'), publishers: row.fetch('publishers').split(';'),
      genres: row.fetch('genres').split(';'), official_title: nil,
      releases: [{ 'system' => 'mvs', 'date' => row.fetch('first_release_date'), 'region' => 'jp', 'source' => 'fbneo' }]
    }
  end

  stats = Hash.new(0)
  candidates.each do |id, metadata|
    path = File.join(ROOT, 'data', 'games', 'neogeo', "#{id}.json")
    abort "Neo Geo game not found: #{id}" unless File.exist?(path)

    game = JSON.parse(File.read(path))
    title_changed = merge_snk_title(game, metadata[:official_title])
    releases_complete = (metadata[:releases] - Array(game['releases'])).empty?
    metadata_complete = game['first_release_date'] && game['publishers'] && game['genres'] && releases_complete
    if metadata_complete && !title_changed
      stats[:unchanged] += 1
      next
    end

    stats[:updated] += 1
    merged = add_metadata(game, metadata[:date], metadata[:publishers], metadata[:genres], metadata[:releases])
    File.write(path, JSON.pretty_generate(merged) + "\n") unless options[:dry_run]
  end

  puts stats.map { |key, count| "#{key}=#{count}" }.join(', ')
  puts '(dry-run)' if options[:dry_run]
end

main if __FILE__ == $PROGRAM_NAME
