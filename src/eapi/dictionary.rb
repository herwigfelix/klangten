# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Elten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3. 
# Elten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details. 
# You should have received a copy of the GNU General Public License along with Elten. If not, see <https://www.gnu.org/licenses/>. 
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten.

require_relative "resources" if !defined?(EltenAPI::Resources)

module EltenAPI
  module Dictionary
    # Klangten display-time branding.
    #
    # The gettext catalogues are shared with upstream Elten. Instead of editing
    # hundreds of msgids, every text returned by _, n_, p_, np_, s_, ns_ and
    # _doc is branded when it is looked up (translated or not):
    #   "EltenLink" -> "Klango"    (the network and its server)
    #   "Elten"     -> "Klangten"  (this client)
    # Only whole, capitalised words are replaced. An occurrence is left alone when
    #   * it is part of a longer word or identifier (Eltenger, EltenAPI, Elten_x),
    #   * it is part of a URL, e-mail address, path or file name, i.e. directly
    #     preceded by / . @ \ - _, directly followed by . / \ and a letter or
    #     digit, or by - and a lower-case letter or digit (elten.link,
    #     github.com/dawidpieper/elten3, Elten.exe, Elten-net); hyphenated
    #     compounds such as "Elten-Programme" are branded,
    #   * it is followed by a version number ("Elten 2.4", "Elten 3.0"): such
    #     texts describe the history of upstream Elten.
    # Common inflected forms are branded too: Eltens (de), Eltena, Eltenie,
    # Eltenem, Eltenowi, Eltenu (pl).
    # The documents 'rules', 'privacypolicy', 'faq' and 'changelog/...' are never
    # branded, and texts that must name Elten or EltenLink literally (licence and
    # fork notices) are built inside unbranded { ... }.
    module Branding
      PATTERN = /(?<![\p{L}\p{N}_\/.@\\-])(EltenLink|Elten)(s|a|u|em|ie|owi)?(?![\p{L}\p{N}_])(?![.\/\\][\p{L}\p{N}])(?!-[\p{Ll}\p{N}])(?!\s+\d)/
      UNBRANDED_DOCUMENTS = /\A(?:rules|privacypolicy|faq|changelog\/.*)\z/
      REPLACEMENTS = { "EltenLink" => "Klango", "Elten" => "Klangten" }.freeze

      def self.apply(text)
        return text unless text.is_a?(String) && text.include?("Elten")
        return text if Thread.current[:klangten_unbranded] == true
        text.gsub(PATTERN) { REPLACEMENTS[$1] + $2.to_s }
      rescue ArgumentError, Encoding::CompatibilityError
        text
      end
    end

    # Runs the block with branding disabled for texts looked up in this thread.
    def unbranded
      previous = Thread.current[:klangten_unbranded]
      Thread.current[:klangten_unbranded] = true
      yield
    ensure
      Thread.current[:klangten_unbranded] = previous
    end

    private
    DictCache={}
    Docs={}
    Params=[]
  Sources=[]
  Translations=[]
  Languages=[]
  def locale_text(value)
    str=value.to_s.dup
    if str.encoding==Encoding::UTF_8
      return str if str.valid_encoding?
    elsif str.encoding==Encoding::ASCII_8BIT
      str.force_encoding(Encoding::UTF_8)
      return str if str.valid_encoding?
    end
    str.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
  rescue Encoding::CompatibilityError, Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
    value.to_s.b.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
  end
  class Language
    attr_accessor :code, :mo, :docs
    def initialize(code="")
      @code=code
      @mo=""
      @docs={}
    end
    def realcode
      value=@code.to_s.tr("_","-")
      if value =~ /\A([a-zA-Z]{2})-([a-zA-Z]{2})\z/
        return $1.downcase+"-"+$2.upcase
      elsif value =~ /\A([a-zA-Z]{2})([a-zA-Z]{2})\z/
        return $1.downcase+"-"+$2.upcase
      end
      value
      end
     end
     def loadedlanguages
      return (Languages.deep_dup)||[] if Languages.respond_to?(:deep_dup)
      Languages.map do |language|
        copy=Language.new(language.code)
        copy.mo=language.mo.to_s.dup
        copy.docs=language.docs.dup
        copy
      end
      end
     def loadlocaledata(file=nil)
       languages=load_resource_locales
       Languages.clear
       languages.each { |language| Languages.push(language) }
     rescue Exception => e
       Log.warning("Cannot load locale resources: #{e.class}: #{e.message}") if defined?(Log)
     end
     def getlocale(code)
       normalized=normalize_locale_code(code)
       lang=nil
     Languages.each do |l|
      if l.realcode.downcase==normalized.downcase
        lang=l
        break
        end
    end
    return lang
       end
       def setlocale(code)
    code=normalize_locale_code(code)
    lang=nil
    Languages.each do |l|
      if l.realcode.downcase==code.downcase
        lang=l
        break
        end
    end
    return if lang==nil
       Docs.clear
       loadmo(lang.mo)

   if defined?(Programs) && Programs.respond_to?(:language_locale_data)
     Programs.language_locale_data(code).each { |data| loadmo(data, false) }
   end
 lang.docs.each do |d|
   Docs[d[0]]=d[1]
   end
end
def loadlocale(file, reset=true)
     loadmo(File.binread(file), reset) if FileTest.exists?(file)
     end
def loadmo(data, reset=true)
          DictCache.clear if reset
        if reset
    Params[0]=nil
  Sources.clear
  Translations.clear
  Params[2]=2
  Params[3]="(n!=1)?1:0"
  Params[1]=0
end
        Params[0]=nil#file if reset
  return if data==nil || data.bytesize<20
  data=data.to_s.b
  magic=data[0..3].unpack("I").first
  return if magic!=0x950412de
  format=data[4..7].unpack("I").first
  return if format!=0
  n=data[8..11].unpack("I").first
  Params[1] ||= 0
  Params[2] ||= 2
  Params[3] ||= "(n!=1)?1:0"
  Params[1]+=n
  src=data[12..15].unpack("I").first
  dst=data[16..19].unpack("I").first
  (0...n).each do |i|
src_length = data[src+8*i..src+8*i+3].unpack("I").first
src_offset = data[src+8*i+4..src+8*i+7].unpack("I").first
dst_length = data[dst+8*i..dst+8*i+3].unpack("I").first
dst_offset = data[dst+8*i+4..dst+8*i+7].unpack("I").first
if reset or !Sources.include?(data[src_offset..src_offset+src_length].split("\0"))
  Sources.push(data[src_offset..src_offset+src_length].split("\0"))
Translations.push(data[dst_offset..dst_offset+dst_length].split("\0"))
if Sources.last==[]
  t=Translations.last
  setparams(t[0]) if t[0].is_a?(String)
end
DictCache[Sources.last.first]||=[]
DictCache[Sources.last.first].push(Sources.size-1)
end
end
end
def _doc(d)
  fallback=getlocale("en-GB")
  text=locale_text(Docs[d]||(fallback!=nil ? fallback.docs[d] : nil)||"")
  return text if d.to_s =~ Branding::UNBRANDED_DOCUMENTS
  Branding.apply(text)
  end
def _(src)
  source = src.to_s
  context = program_translation_context
  if context != nil
    translated = translate_context(context, source)
    return Branding.apply(translated) if translated != nil
  end
  Branding.apply(find(source)[0])
end
def n_(*pr)
 context = program_translation_context
 if context != nil
   translated = translate_context_plural(context, *pr)
   return Branding.apply(translated) if translated != nil
 end
 forms=[]
 n=0
 pr.each do |param|
   if param.is_a?(String)
   forms.push(param)
 elsif param.is_a?(Integer)
   n=param
   end
 end
 f=find(*forms)
 Branding.apply(f[pluralform(n)]||f.last)
end
def p_(context, src)
  Branding.apply(translate_context(context, src) || src.to_s)
end
def s_(str)
  s=unbranded { _(str) }
  if s==str
    return Branding.apply(str[str.index("|")+1..-1])
  else
    return Branding.apply(str)
    end
  end
  def np_(context, src, *params)
  translated = translate_context_plural(context, src, *params)
  translated != nil ? Branding.apply(translated) : n_(src, *params)
end
def ns_(context, src, *params)
  str=unbranded { n_(context+"|"+src, *params) }
  Branding.apply(str.sub(context+"|",""))
end
def N_(*params);end
  def Nn_(*params);end
private
def normalize_locale_code(code)
  value=code.to_s.tr("_","-")
  if value =~ /\A([a-zA-Z]{2})-([a-zA-Z]{2})\z/
    return $1.downcase+"-"+$2.upcase
  elsif value =~ /\A([a-zA-Z]{2})([a-zA-Z]{2})\z/
    return $1.downcase+"-"+$2.upcase
  end
  value
end

def load_resource_locales
  keys=EltenAPI::Resources.keys("locale", base: ".")
  by_code={}
  keys.each do |key|
    parts=key.split("/")
    next if parts[0]!="locale" || parts[1].to_s==""
    code=normalize_locale_code(parts[1])
    next if code==""
    by_code[code]||=[]
    by_code[code] << key
  end
  by_code.keys.sort_by(&:downcase).map do |code|
    build_resource_locale(code, by_code[code])
  end.compact
end

def build_resource_locale(code, keys)
  lang=Language.new(code)
  mo_key=keys.find { |key| key =~ /\Alocale\/[^\/]+\/lc_messages\/[^\/]+\.mo\z/i }
  lang.mo=EltenAPI::Resources.read(mo_key, base: ".").to_s.b if mo_key!=nil
  keys.each do |key|
    next if File.extname(key).downcase!=".md"
    relative=key.split("/")[2..-1].join("/")
    next if relative.to_s=="" || relative.downcase.start_with?("lc_messages/")
    name=relative.sub(/\.md\z/i, "")
    doc=EltenAPI::Resources.read(key, base: ".")
    lang.docs[locale_text(name)]=locale_text(doc) if doc!=nil
  end
  return nil if lang.mo.to_s=="" && lang.docs.empty?
  lang
end

def program_translation_context
  runtime = Programs.current_runtime
  runtime = Programs.runtime_from_caller if runtime == nil
  return nil if runtime == nil || runtime.manifest == nil
  runtime.manifest.name
rescue Exception
  nil
end

def translate_context(context, src)
  separator = 4.chr
  key = context.to_s + separator + src.to_s
  translated = find(key)[0]
  return nil if translated == key
  translated.gsub(context.to_s + separator, "")
end

def translate_context_plural(context, src, *params)
  separator = 4.chr
  forms = [context.to_s + separator + src.to_s]
  n = 0
  params.each do |param|
    if param.is_a?(String)
      forms << param.to_s
    elsif param.is_a?(Integer)
      n = param
    end
  end
  found = find(*forms)
  translated = found[pluralform(n)] || found.last
  return nil if forms.include?(translated)
  translated.gsub(context.to_s + separator, "")
end

def find(*forms)
  c=DictCache[forms.first]
  return forms if c==nil
  c.each do |i|
    return Translations[i].map{|s|s.force_encoding(Encoding::UTF_8)} if Sources[i].size>=forms.size && Sources[i][0...forms.size]==forms
  end
  return forms.map{|s|s.force_encoding(Encoding::UTF_8)}
end
def setparams(t)
  pr=t.split("\n")
  pr.each do |param|
    c=param.index(": ")
    next if c==nil
    head=param[0...c]
    val=param[c+2..-1]
    if head=='Plural-Forms'
      parse_plurals(val)
      end
    end
  end
  def parse_plurals(pl)
    pl=pl.delete(" \t")
    if (/Params[2]=(\d+)/=~pl)!=nil
      Params[2]=$1.to_i
    end
    if (/plural=([^;]+);/=~pl)!=nil
      Params[3]=$1
    end
  end
  def pluralform(n)
    eval(Params[3]).to_i
  rescue Exception
    return 0
    end
  end
  include Dictionary
  end
