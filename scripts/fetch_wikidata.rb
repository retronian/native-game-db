#!/usr/bin/env ruby
# frozen_string_literal: true

# Wikidata SPARQL から指定プラットフォームのゲームデータを取得し、
# native-game-db スキーマの JSON ファイルを data/games/{platform}/ に出力する。
#
# 使用方法:
#   ruby scripts/fetch_wikidata.rb gb
#   ruby scripts/fetch_wikidata.rb fc --limit 50
#   ruby scripts/fetch_wikidata.rb sfc --dry-run

require 'json'
require 'fileutils'
require 'tempfile'
require 'optparse'
require_relative 'lib/script_detector'

WIKIDATA_ENDPOINT = 'https://query.wikidata.org/sparql'
ROOT = File.expand_path('..', __dir__)
USER_AGENT = 'native-game-db/0.1 (https://github.com/retronian/native-game-db)'

# プラットフォーム識別子 → Wikidata QID
PLATFORMS = {
  'fc'  => { qid: 'Q172742',  name: 'Famicom / NES' },
  'sfc' => { qid: 'Q183259',  name: 'Super Famicom / SNES' },
  'gb'  => { qid: 'Q186437',  name: 'Game Boy' },
  'gbc' => { qid: 'Q203992',  name: 'Game Boy Color' },
  'gba' => { qid: 'Q188642',  name: 'Game Boy Advance' },
  'md'  => { qid: 'Q10676',   name: 'Mega Drive / Genesis' },
  'pce' => { qid: 'Q1057377', name: 'PC Engine / TurboGrafx-16' },
  'n64' => { qid: 'Q184839',  name: 'Nintendo 64' },
  'nds' => { qid: 'Q170323',  name: 'Nintendo DS' }
}.freeze

def build_query(platform_qid)
  <<~SPARQL
    SELECT DISTINCT ?item ?jaLabel ?enLabel ?pubDate ?igdbId ?mobyId WHERE {
      ?item wdt:P31 wd:Q7889 .
      ?item wdt:P400 wd:#{platform_qid} .

      ?item rdfs:label ?jaLabel .
      FILTER(LANG(?jaLabel) = "ja")

      OPTIONAL {
        ?item rdfs:label ?enLabel .
        FILTER(LANG(?enLabel) = "en")
      }
      OPTIONAL { ?item wdt:P577  ?pubDate . }
      OPTIONAL { ?item wdt:P5794 ?igdbId . }
      OPTIONAL { ?item wdt:P11688 ?mobyId . }
    }
    ORDER BY ?jaLabel
  SPARQL
end

def fetch(query)
  Tempfile.create(['sparql', '.rq']) do |f|
    f.write(query)
    f.flush

    url = "#{WIKIDATA_ENDPOINT}?format=json"
    result = `curl -s -X POST "#{url}" \
      -H "Content-Type: application/sparql-query" \
      -H "Accept: application/sparql-results+json" \
      -H "User-Agent: #{USER_AGENT}" \
      --data-binary @#{f.path}`

    abort "SPARQL クエリ失敗" unless $?.success? && !result.empty?
    JSON.parse(result)
  end
end

# 英語ラベルから slug を生成（ASCII のみ）
# 例: "Kirby's Dream Land" -> "kirbys-dream-land"
def slugify(text)
  return nil if text.nil? || text.empty?
  # Latin Extended を ASCII 近似にフォールバック
  ascii = text.unicode_normalize(:nfkd).encode('ASCII', invalid: :replace, undef: :replace, replace: '')
  ascii.downcase
       .gsub(/[^a-z0-9\s-]+/, '')
       .strip
       .gsub(/\s+/, '-')
       .gsub(/-+/, '-')
       .gsub(/^-+|-+$/, '')
end

# Wikidata の ja ラベルから曖昧さ回避 suffix を除去
# 例: "Centipede (ゲーム)" -> "Centipede"
# 例: "F-1 Race (ゲームボーイ)" -> "F-1 Race"
DISAMBIG_RE = /\s*[(（](?:ゲーム|ビデオゲーム|コンピュータゲーム|ゲームボーイ|ファミリーコンピュータ|スーパーファミコン|任天堂|[0-9]{4}年のゲーム)[^)）]*[)）]\s*\z/.freeze

def clean_ja_label(text)
  return text if text.nil?
  text.sub(DISAMBIG_RE, '').strip
end

# 1 SPARQL binding -> スキーマ形式の Ruby ハッシュ（1 ゲーム分）
def build_entry(binding, platform_id)
  wikidata_id = binding.dig('item', 'value')&.split('/')&.last
  ja_label    = clean_ja_label(binding.dig('jaLabel', 'value'))
  en_label    = binding.dig('enLabel', 'value')
  pub_date    = binding.dig('pubDate', 'value')&.split('T')&.first
  igdb_id     = binding.dig('igdbId',  'value')
  moby_id     = binding.dig('mobyId',  'value')

  return nil if ja_label.nil? || ja_label.empty?

  # slug: 英語ラベル優先、無ければ wikidata QID
  id = slugify(en_label) || wikidata_id&.downcase
  return nil if id.nil? || id.empty?

  titles = []

  titles << {
    'text'     => ja_label,
    'lang'     => 'ja',
    'script'   => ScriptDetector.detect(ja_label),
    'region'   => 'jp',
    'form'     => 'official',
    'source'   => 'wikidata',
    'verified' => false
  }

  if en_label && en_label != ja_label
    titles << {
      'text'     => en_label,
      'lang'     => 'en',
      'script'   => ScriptDetector.detect(en_label),
      'region'   => 'us',
      'form'     => 'official',
      'source'   => 'wikidata',
      'verified' => false
    }
  end

  entry = {
    'id'       => id,
    'platform' => platform_id,
    'category' => 'main_game',
    'titles'   => titles
  }

  entry['first_release_date'] = pub_date if pub_date

  external_ids = {}
  external_ids['wikidata']  = wikidata_id if wikidata_id
  external_ids['igdb']      = igdb_id.to_i if igdb_id && igdb_id.to_i.positive?
  external_ids['mobygames'] = moby_id.to_i if moby_id && moby_id.to_i.positive?
  entry['external_ids'] = external_ids unless external_ids.empty?

  entry
end

def write_entry(entry, platform_id, dry_run: false)
  dir = File.join(ROOT, 'data', 'games', platform_id)
  FileUtils.mkdir_p(dir) unless dry_run
  path = File.join(dir, "#{entry['id']}.json")

  if File.exist?(path) && !dry_run
    # 既存ファイルは上書きしない（手動編集保護）
    return :skipped
  end

  if dry_run
    :would_write
  else
    File.write(path, JSON.pretty_generate(entry) + "\n")
    :written
  end
end

def main
  options = { limit: nil, dry_run: false }
  parser = OptionParser.new do |opts|
    opts.banner = "Usage: ruby scripts/fetch_wikidata.rb PLATFORM [options]\n" \
                  "  PLATFORM: #{PLATFORMS.keys.join(', ')}"
    opts.on('--limit N', Integer, '処理件数を制限（デバッグ用）') { |n| options[:limit] = n }
    opts.on('--dry-run', 'ファイルを書き込まずに件数のみ表示') { options[:dry_run] = true }
  end
  parser.parse!

  platform_id = ARGV.shift
  unless PLATFORMS.key?(platform_id)
    warn parser.help
    exit 1
  end

  meta = PLATFORMS[platform_id]
  puts "=== Wikidata fetch: #{meta[:name]} (#{meta[:qid]}) ==="
  puts

  query = build_query(meta[:qid])
  data  = fetch(query)
  bindings = data.dig('results', 'bindings') || []
  puts "SPARQL 返却件数: #{bindings.size}"
  puts

  bindings = bindings.first(options[:limit]) if options[:limit]

  stats = Hash.new(0)
  seen_ids = {}
  script_stats = Hash.new(0)

  bindings.each do |b|
    entry = build_entry(b, platform_id)
    if entry.nil?
      stats[:skipped_invalid] += 1
      next
    end

    if seen_ids[entry['id']]
      # 同一 id 衝突 → wikidata QID を suffix
      qid = entry.dig('external_ids', 'wikidata')
      entry['id'] = "#{entry['id']}-#{qid.downcase}" if qid
    end
    seen_ids[entry['id']] = true

    ja_title = entry['titles'].find { |t| t['lang'] == 'ja' }
    script_stats[ja_title['script']] += 1 if ja_title

    result = write_entry(entry, platform_id, dry_run: options[:dry_run])
    stats[result] += 1
  end

  puts "=== 結果 ==="
  stats.each { |k, v| puts "  #{k}: #{v}" }
  puts
  puts "=== 日本語タイトルの script 分布 ==="
  script_stats.sort_by { |_, v| -v }.each { |k, v| puts "  #{k}: #{v}" }
end

main if __FILE__ == $PROGRAM_NAME