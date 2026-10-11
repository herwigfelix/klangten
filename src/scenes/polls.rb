# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Elten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3. 
# Elten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details. 
# You should have received a copy of the GNU General Public License along with Elten. If not, see <https://www.gnu.org/licenses/>. 
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten: polls by author, language and group, own polls as drafts (edit, publish, withdraw), answer drafts.

class Scene_Polls
  # Klangten: source = nil (all polls) or [:author, name], [:language, code],
  # [:group, id, name] - the list then shows only these polls.
  def initialize(lastpoll=0, source=nil)
    @lastpoll=lastpoll
    @source=source
    end
  def main
    header=p_("Polls", "Polls")
    header=p_("Polls", "Polls: %{source}")%{:source=>@source[2].to_s} if @source!=nil
    @sel=TableBox.new([nil, p_("Polls", "Author"), p_("Polls", "Votes"), nil], [], index: 0, header: header)
@sel.bind_context{|menu|context(menu)}
@allpolls=[]
refresh
@polls=[]
polls_filter
@sel.focus
loop do
  loop_update
  @sel.update
  # Klangten: from a filtered list Escape returns to all polls.
  $scene=(@source!=nil ? Scene_Polls.new : Scene_Main.new) if key_pressed?(:key_escape)
      if key_pressed?(:key_enter) and @sel.options.size>0
                 selt=[p_("Polls", "Vote"),p_("Polls", "Show results"), p_("Polls", "Show report")]
       if Session.logged?
         begin
           voted=EltenLink::Polls.voted?(elten_link, @polls[@sel.index])
         rescue EltenLink::Error
         alert(_("Error"))
         $scene=Scene_Main.new
         return
       end
       if voted
         selt[0]=nil
end
       end         
       if !Session.logged? || @banned
         selt[0]=""
         end
         case menuselector(selt)
         when 0
           $scene=Scene_Polls_Answer.new(@polls[@sel.index].id, back_scene)
           when 1
             $scene=Scene_Polls_Results.new(@polls[@sel.index].id, back_scene)
             when 2
               $scene=Scene_Polls_Report.new(@polls[@sel.index].id, back_scene)
               end
        end
  break if $scene!=self
  end
end
def refresh
  @banned=false
  @banned=isbanned(Session.name) if Session.logged?
  begin
    @allpolls=case (@source||[])[0]
    when :author then EltenLink::Polls.by_author(elten_link, @source[1])
    when :language then EltenLink::Polls.by_language(elten_link, @source[1])
    when :group then EltenLink::Polls.group_polls(elten_link, @source[1])
    else EltenLink::Polls.list(elten_link, details: 2)
    end
  rescue EltenLink::Error
  alert(_("Error"))
  $scene=Scene_Main.new
  return
end
      end
def polls_filter
  @lastpoll=@polls[@sel.index].id if @polls.is_a?(Array) and @polls.size>0
  @polls=[]
knownlanguages = Session.languages.split(",").map{|lg|lg.upcase}
for pl in @allpolls
  # Klangten: a chosen author, language or group shows all of its polls.
  @polls.push(pl) if @source!=nil || LocalConfig["PollsShowUnknownLanguages", type: :bool] || knownlanguages.size==0 || knownlanguages.include?(pl.language[0..1].upcase)
  end
selt=[]
index=0
for poll in @polls
if poll != nil
  selt.push([poll.name, poll.author, poll.votes.to_s, poll.description])
    index=selt.size-1 if poll.id==@lastpoll
  end
end
    @sel.rows=selt
    @sel.reload
    @sel.index=index
  end
# Klangten: where Vote/Results/Report return to (the filtered list, if any).
def back_scene
  return nil if @source==nil
  Scene_Polls.new(@polls[@sel.index].id, @source)
end
# Klangten: chooses an author, language or group and shows its polls.
def choose_source(kind)
  begin
    case kind
    when :author
      rows=EltenLink::Polls.authors(elten_link)
      labels=rows.map{|r|np_("Polls", "%{name}, %{count} poll", "%{name}, %{count} polls", r[1])%{:name=>r[0], :count=>r[1]}}
      empty=p_("Polls", "There are no public polls.")
      header=p_("Polls", "Author")
    when :language
      rows=EltenLink::Polls.languages(elten_link)
      labels=rows.map{|r|np_("Polls", "%{name}, %{count} poll", "%{name}, %{count} polls", r[2])%{:name=>(r[1]!="" ? r[1] : p_("Polls", "No language")), :count=>r[2]}}
      empty=p_("Polls", "There are no public polls.")
      header=p_("Polls", "Poll language")
    else
      rows=EltenLink::Community.groups(elten_link)
      labels=rows.map{|g|g.name}
      empty=p_("Polls", "You are not a member of any Klango group.")
      header=p_("Polls", "Group")
    end
  rescue EltenLink::Error
    alert(_("Error"))
    return
  end
  return alert(empty) if rows.empty?
  index=selector(labels, header: header, start_index: 0, cancel_index: -1)
  return if index==nil || index<0
  row=rows[index]
  source=case kind
  when :author then [:author, row[0], row[0]]
  when :language then [:language, row[0], labels[index]]
  else [:group, row.id, row.name]
  end
  $scene=Scene_Polls.new(0, source)
end
def context(menu)
                  if @sel.options.size>0
                           if Session.logged? && !@banned
                             if !@polls[@sel.index].voted
         menu.option(p_("Polls", "Vote"), nil, "v") {
                    $scene=Scene_Polls_Answer.new(@polls[@sel.index].id, back_scene)
                  }
                end
                end
         menu.option(p_("Polls", "Show results"), nil, "t") {
                      $scene=Scene_Polls_Results.new(@polls[@sel.index].id, back_scene)
         }
                  menu.option(p_("Polls", "Show report"), nil, "p") {
                      $scene=Scene_Polls_Report.new(@polls[@sel.index].id, back_scene)
         }
         if Session.moderator==1 or @polls[@sel.index].author==Session.name
         menu.option(_("Delete"), nil, :del) {
                        if confirm(p_("Polls", "Do you really want to delete %{name}?")%{:name=>@polls[@sel.index].name})
                 begin
                   EltenLink::Polls.delete(elten_link, @polls[@sel.index])
                 rescue EltenLink::Error
                   alert(_("Error"))
                 else
                   alert(p_("Polls", "deleted"))
                   refresh
                   polls_filter
                   @sel.focus
                 end
                 speech_wait
                 end
         }
         end
       end
       if Session.languages.size>0
         s=p_("Polls", "Show polls in unknown languages")
      s=p_("Polls", "Hide polls in unknown languages") if LocalConfig['PollsShowUnknownLanguages', type: :bool]
      menu.option(s) {
      LocalConfig['PollsShowUnknownLanguages'] = !LocalConfig['PollsShowUnknownLanguages', type: :bool]
polls_filter
@sel.focus
      }
    end
    if Session.logged? && !@banned
         menu.option(p_("Polls", "New poll"), nil, "n") {
                        $scene = Scene_Polls_Create.new
         }
         menu.option(p_("Polls", "My polls and drafts"), nil, "m") {
           $scene = Scene_Polls_Mine.new
         }
         end
    # Klangten: browse the polls like Klango's tree (by author, language, group).
    menu.submenu(p_("Polls", "Browse polls")) {|m|
    m.option(p_("Polls", "By author")) { choose_source(:author) }
    m.option(p_("Polls", "By language")) { choose_source(:language) }
    m.option(p_("Polls", "Polls of my groups")) { choose_source(:group) } if Session.logged?
    m.option(p_("Polls", "All polls")) { $scene=Scene_Polls.new } if @source!=nil
    }
         menu.option(_("Refresh"), nil, "r") {
                                         $scene=Scene_Polls.new
         }
         end
end

class Scene_Polls_Create
  # Klangten: with a poll (EltenLink::PollDetails of an own poll) the form
  # edits it instead of creating a new one; toscene is where it returns to.
  def initialize(poll=nil, toscene=nil)
    @poll=poll
    @toscene=toscene
  end
  def back
    @toscene || Scene_Polls.new
  end
  def main
      @ln = []
      ls=[]
    lnindex = 0
    for lk in Lists.langs.keys
      l = Lists.langs[lk]
      ls.push(l["name"] + " (" + l["nativeName"] + ")")
      @ln.push(lk)
      lnindex = @ln.size - 1 if Configuration.language.downcase[0..1] == lk.downcase[0..1]
    end
    if @poll!=nil
      found=@ln.index{|lk|lk.downcase[0..1]==@poll.language.to_s.downcase[0..1]}
      lnindex=found if found!=nil
    end
    # Klangten: a new poll can also be published in one of my Klango groups.
    @groups=[]
    if @poll==nil
      begin
        @groups=EltenLink::Community.groups(elten_link)
      rescue EltenLink::Error => e
        Log.warning("Poll groups failed: #{e.message}")
      end
    end
    @fields=[EditBox.new(p_("Polls", "Poll name"),text: @poll ? @poll.name.to_s : "",quiet: true),EditBox.new(p_("Polls", "Description"),type: EditBox::Flags::MultiLine,text: @poll ? @poll.description.to_s : "",quiet: true),ListBox.new(ls, header: p_("Polls", "Poll language"), index: lnindex),ListBox.new([],header: p_("Polls", "Questions")), CheckBox.new(p_("Polls", "Set the expiry date for this poll")), DateButton.new(p_("Polls", "Expiry date"), (Time.now.year..(Time.now.year+3)), include_hour: true), CheckBox.new(p_("Polls", "Hide poll results before the expiry date")), CheckBox.new(p_("Polls", "Hide this poll")),
    ListBox.new([p_("Polls", "Everyone")]+@groups.map{|g|p_("Polls", "Group %{name}")%{:name=>g.name}}, header: p_("Polls", "Who can vote")),
    Button.new(@poll ? _("Save") : p_("Polls", "Create")),Button.new(p_("Polls", "Save as draft")),Button.new(_("Cancel"))]
    @fields[3].bind_context{|menu|questions_context(menu)}
  @form=Form.new(@fields)
    @fields[4].on(:change) {
    if !@fields[4].checked || @poll!=nil
      @form.hide(5)
      @form.hide(6)
    else
      @form.show(5)
      @form.show(6)
      end
    }
    @fields[8].on(:move) {
    # a group poll is visible to the members only, so "hide" makes no sense there
    if @fields[8].index>0 || @poll!=nil
      @form.hide(7)
    else
      @form.show(7)
    end
    }
    @fields[4].trigger(:change)
    @fields[8].trigger(:move)
    if @poll!=nil
      @form.hide(4)
      @form.hide(8)
      @form.hide(10)
    end
    @form.hide(8) if @groups.empty?
  @questions=[]
  if @poll!=nil
    @questions=@poll.questions.map{|q|q.dup}
    @fields[3].options=@questions.map{|q|q[0].to_s}
  end
  loop do
    loop_update
    @form.update
     if @fields[9].pressed?
       @poll!=nil ? savepoll : sendpoll
break if $scene!=self
end
     if @fields[10].pressed?
       sendpoll(true)
       break if $scene!=self
     end
if @fields[11].pressed? or key_pressed?(:key_escape)
  confirm(p_("Polls", "Are you sure you want to discard this poll?")) {
  $scene=back
           return
           break
           }
     end
    end
  end
  # Klangten: saves the changes of an own poll.
  def savepoll
    if @fields[0].text.to_s.strip==""
      alert(p_("Polls", "Please complete the poll before sending"))
      return
    end
    begin
      locked=EltenLink::Polls.edit(elten_link, @poll, name: @fields[0].text, description: @fields[1].text, language: @ln[@fields[2].index], questions: (@poll.locked ? nil : @questions))
    rescue EltenLink::Error => e
      alert(e.message.to_s!="" ? e.message.to_s : _("Error"))
    else
      alert(locked ? p_("Polls", "The poll has been saved. Its questions cannot be changed any more.") : p_("Polls", "The poll has been saved."))
      $scene=back
    end
  end
  def questions_context(menu)
    if @poll!=nil && @poll.locked
      menu.option(p_("Polls", "Why can't I change the questions?")) {
      alert(p_("Polls", "The questions of a published poll or a poll with votes cannot be changed any more. Withdraw the poll first; once someone has voted, the questions stay as they are."))
      }
      return
    end
    menu.option(p_("Polls", "New question"), nil, "n") {
    editquestion(@questions.size)
    }
    if @questions.size>0
      menu.option(p_("Polls", "Edit question"), nil, "e") {
      editquestion(@fields[3].index)
      }
      menu.option(p_("Polls", "Delete question"), nil, :del) {
            @questions.delete_at(@fields[3].index)
      @fields[3].options.delete_at(@fields[3].index)
      play_sound("editbox_delete")
      @fields[3].say_option
      }
      end
    end
  def editquestion(q)
       qs=@questions[q]
       @question=@questions[q].deep_dup
              @question=["",0] if @question==nil
       @qfields=[
       edt_title = EditBox.new(p_("Polls", "Question"),text: @question[0],quiet: true),
       lst_type=ListBox.new([p_("Polls", "Single choice"),p_("Polls", "Multiple choice"),p_("Polls", "Text field")],header: p_("Polls", "Question type"),index: (@question[1].to_i<0 ? 1 : @question[1].to_i)),
       chk_limit = CheckBox.new(p_("Polls", "Limit the number of answers that can be selected"), checked: @question[1].to_i<0),
       edt_limit = EditBox.new(p_("Polls", "Maximum number of answers that can be selected"), type: EditBox::Flags::Numbers, text: (@question[1].to_i<0 ? (-@question[1].to_i).to_s : "2")),
      
       lst_answers = ListBox.new(@question[2..-1]||[],header: p_("Polls", "Answers")),
       btn_save = Button.new(_("Save")),
       btn_cancel = Button.new(_("Cancel"))
       ]
       chk_limit.on(:change) {
       if chk_limit.checked
         @qform.show(edt_limit)
       else
         @qform.hide(edt_limit)
         end
       }
       lst_type.on(:move) {
                if lst_type.index<2
@qform.show(lst_answers)           
         elsif lst_type.index==2
           @qform.hide(lst_answers)
         end
         if lst_type.index==1
           @qform.show(chk_limit)
           chk_limit.trigger(:change)
         else
           @qform.hide(chk_limit)
           @qform.hide(edt_limit)
           end
       }
              lst_answers.bind_context{|menu|answers_context(menu)}
       @qform=Form.new(@qfields)
       lst_type.trigger(:move)
              loop do
         loop_update
         @qform.update
           if btn_cancel.pressed? or key_pressed?(:key_escape)
  loop_update
    break
  end
  if btn_save.pressed?
    loop_update
  if @question.size>3 or lst_type.index==2
  @question[0]=edt_title.text
  if lst_type.index==1 && chk_limit.checked
    @question[1]=-edt_limit.text.to_i
    if @question[1] == -1
      @question[1]=0
    elsif @question[1]>=0
      @question[1]=1
      end
    else
  @question[1]=lst_type.index
  end
  @questions[q]=@question
  break
elsif @question.size==2
  alert(p_("Polls", "There are no answers to this question"))
else
  alert(p_("Polls", "There is only one answer to this question."))
    end
  end
  end
qu=[]
           for q in @questions
  qu.push(q[0]) if q!=nil
  end
  @fields[3].options = qu
  @fields[3].focus
end
def answers_context(menu)
  menu.option(p_("Polls", "New answer"), nil, "n") {
  editanswer(@question.size-2)
  }
  if @qfields[4].options.size>0
    menu.option(p_("Polls", "Edit answer"), nil, "e") {
        editanswer(@qfields[4].index)
    }
      menu.option(p_("Polls", "Delete answer"), nil, :del) {
      @question.delete_at(@qfields[4].index+2)
      @qfields[4].options.delete_at(@qfields[4].index)
      play_sound("editbox_delete")
      @qfields[4].say_option
      }
    end
  end
  def editanswer(a)
    old=@question[2+a]||""
      ans=input_text(p_("Polls", "Answer"),flags: 0,text: old,escapable: true)
      if ans!=nil
            @question[2+a]=ans
          end
                            @qfields[4].options=@question[2..-1]||[]
@qfields[4].focus      
end
def sendpoll(draft=false)
  if (!draft && @questions.size==0) || @fields[0].text.to_s.strip=="" || (!draft && @fields[4].checked && @fields[5].year==0)
    alert(p_("Polls", "Please complete the poll before sending"))
    return
    end
  group=draft ? nil : @groups[@fields[8].index-1] if @fields[8].index>0
expirydate = nil
hideresults = false
if @fields[4].checked
  expirydate=Time.local(@fields[5].year, @fields[5].month, @fields[5].day, @fields[5].hour, @fields[5].min, @fields[5].sec).to_i
  hideresults=@fields[6].checked
  end
begin
  EltenLink::Polls.create(
    elten_link,
    name: @fields[0].text,
    language: @ln[@form.fields[2].index],
    hidden: @fields[7].checked && group==nil,
    expirydate: expirydate,
    hideresults: hideresults,
    questions: @questions,
    description: @fields[1].text,
    draft: draft,
    groupid: group ? group.id : nil
  )
rescue EltenLink::Error => e
  alert(e.message.to_s!="" ? e.message.to_s : _("Error"))
else
  if draft
    alert(p_("Polls", "The poll has been saved as a draft. You find it under My polls and drafts."))
  elsif group!=nil
    alert(p_("Polls", "The poll has been created for the members of %{group}.")%{:group=>group.name})
  else
  alert(p_("Polls", "The poll has been created."))
  end
  $scene=back
end
  end
  end

  class Scene_Polls_Answer
  def initialize(id,toscene=nil)
    @id=id
    @toscene=toscene
    end
  def main
    @changed=false
begin
  poll=EltenLink::Polls.get(elten_link, @id)
rescue EltenLink::Error
  alert(_("Error"))
  if @toscene==nil
               $scene=Scene_Polls.new
             else
               $scene=@toscene
               end
  return
end
@name=poll.name
@author=poll.author
@created=poll.created
@questions=poll.questions
@description=poll.description
    txt="#{@name}\r\n#{p_("Polls", "Author")}: #{@author}\r\n#{p_("Polls", "Created")}: #{format_date(@created)}\r\n\r\n#{@description}"
    qs=[]
for q in @questions
  if q[1]==2
    qs.push(EditBox.new(q[0],text: "",quiet: true))
    qs.last.on(:change) {@changed=true}
  else
    comment=""
    if q[1]==0
      multi=false
      limit=1
      comment=p_("Polls", "Single choice question")
          elsif q[1]==1
      multi=true
      limit=-1
      comment=p_("Polls", "Multiple choice question")
    elsif q[1]<=-1
      multi=true
      limit=-q[1]
      comment=np_("Polls", "Question allowing up to %{limit} choices", "Questions allowing up to %{limit} choices", limit)%{:limit=>limit}
    end
    flags=0
    flags|=ListBox::Flags::MultiSelection if multi
        qs.push(ListBox.new(q[2..q.size-1],header: q[0]+" (#{comment}): ",index: 0,flags: flags))
        qs.last.limit=limit
        qs.last.on(:move) {@changed=true}
    end
  end
  
@fields=[EditBox.new(p_("Polls", "Poll"),type: EditBox::Flags::MultiLine|EditBox::Flags::ReadOnly,text: txt,quiet: true)]+qs+[Button.new(p_("Polls", "Vote")),Button.new(p_("Polls", "Save my answers for later")),Button.new(_("Cancel"))]
@form=Form.new(@fields)
# Klangten: answers saved earlier (Klango's poll drafts) are filled in again.
load_draft
loop do
  loop_update
  @form.update
  if key_pressed?(:key_escape)
    if @changed==false or confirm(p_("Polls", "Are you sure you want to discard your answers in this poll?"))
    if @toscene==nil
               $scene=Scene_Polls.new(@id)
             else
               $scene=@toscene
             end
    return
    break
    end
  end
if key_pressed?(:key_enter) or key_pressed?(:key_space)
  if @form.index==@form.fields.size-2
    begin
      EltenLink::Polls.save_answer_draft(elten_link, @id, collect_answers)
    rescue EltenLink::Error => e
      alert(e.message.to_s!="" ? e.message.to_s : _("Error"))
    else
      @changed=false
      alert(p_("Polls", "Your answers have been saved. You can complete and send them later."))
      $scene=(@toscene==nil ? Scene_Polls.new(@id) : @toscene)
      return
    end
  end
  if @form.index==@form.fields.size-3
    ans=""
    for i in 1..@questions.size
case @questions[i-1][1]
when 0
  ans+=(i-1).to_s+":"+@form.fields[i].index.to_s+"\r\n"
  when 1
for j in 0..@form.fields[i].options.size-1
    ans+=(i-1).to_s+":"+j.to_s+"\r\n" if @form.fields[i].selected[j]==true
  end
  when 2
    ans+=(i-1).to_s+":"+@form.fields[i].text.gsub(";"," ").gsub(":"," ").delete("\r\n")+"\r\n" if @form.fields[i].text!=""
  else
    if @questions[i-1][1]<0
    for j in 0..@form.fields[i].options.size-1
    ans+=(i-1).to_s+":"+j.to_s+"\r\n" if @form.fields[i].selected[j]==true
  end
  end
end
    end
    ans.chop!
        begin
          EltenLink::Polls.answer(elten_link, @id, ans)
        rescue EltenLink::Error
      alert(_("Error"))
    else
      alert(p_("Polls", "Your vote has been saved."))
      if @toscene==nil
               $scene=Scene_Polls.new(@id)
             else
               $scene=@toscene
               end
    return
    break
      end      
    elsif @form.index==@form.fields.size-1
        next if @changed!=false && !confirm(p_("Polls", "Are you sure you want to discard your answers in this poll?"))
        if @toscene==nil
               $scene=Scene_Polls.new(@id)
             else
               $scene=@toscene
               end
    return
    break
    end
  end
  end
        end
  end
  
  class Scene_Polls_Answer
  # Klangten: the answers of the form as answer lines ("question:answer").
  def collect_answers
    lines=[]
    @questions.each_with_index do |q, i|
      field=@form.fields[i+1]
      if q[1]==2
        text=field.text.to_s.gsub(";"," ").gsub(":"," ").delete("\r\n")
        lines.push("#{i}:#{text}") if text!=""
      elsif q[1]==0
        lines.push("#{i}:#{field.index}")
      else
        for j in 0...field.options.size
          lines.push("#{i}:#{j}") if field.selected[j]==true
        end
      end
    end
    lines.join("\n")
  end
  def load_draft
    return if !Session.logged?
    draft=nil
    begin
      draft=EltenLink::Polls.answer_draft(elten_link, @id)
    rescue EltenLink::Error => e
      Log.warning("Poll answer draft failed: #{e.message}")
    end
    return if draft==nil
    draft.split("\n").each do |line|
      q, value = line.split(":", 2)
      next if value==nil || q !~ /\A\d+\z/
      q=q.to_i
      question=@questions[q]
      field=@form.fields[q+1]
      next if question==nil || field==nil
      if question[1]==2
        field.set_text(value)
      elsif question[1]==0
        field.index=value.to_i
      else
        field.selected[value.to_i]=true if value.to_i<field.options.size
      end
    end
    alert(p_("Polls", "Your saved answers have been filled in."), false)
  end
  end

  class Scene_Polls_Report
    def initialize(id,toscene=nil)
      @id=id
      @toscene=toscene
    end
    def main
      begin
        poll=EltenLink::Polls.get(elten_link, @id)
      rescue EltenLink::Error
  alert(_("Error"))
  $scene=Scene_Polls.new
  return
end
@name=poll.name
@author=poll.author
@created=poll.created
@questions=poll.questions
@description=poll.description
  txt="#{@name}\r\n#{p_("Polls", "Author")}: #{@author}\r\n#{p_("Polls", "Created")}: #{format_date(@created)}\r\n\r\n#{@description}\r\n"
     begin
       results=EltenLink::Polls.results(elten_link, @id, details: 1)
     rescue EltenLink::Error
  alert(_("Error"))
  if @toscene==nil
               $scene=Scene_Polls.new
             else
               $scene=@toscene
               end
  return
end
txt+="#{p_("Polls", "The number of votes")}: #{results.votes}\r\n"
@votes=results.votes
@answers=[]
results.answers.each do |answer|
  r=answer.author
  q=answer.question
  a=answer.answer
    @answers[q]=[] if @answers[q]==nil
  a=a.to_i if @questions[q][1]<2
  b=[r,a]
    @answers[q].push(b)
end
for q in 0..@questions.size-1
  if @answers[q]!=nil
  txt+=@questions[q][0].to_s+"\r\n"
if @questions[q][1]<2
   for i in 2...@questions[q].size
   a=i-2
pr=(@answers[q].map{|x|x[1]}.count(a).to_f/@votes.to_f*100.0).to_i
txt+=@questions[q][i]+": "+pr.to_s+"%\r\n"
   end
else
  for a in @answers[q]
    txt+=": "+a[1]+"\r\n"
    end
end  
end
txt+="\r\n\r\n"
  end
input_text(p_("Polls", "Poll results: %{name}")%{:name => @name},flags: EditBox::Flags::ReadOnly,text: txt)
if @toscene==nil
               $scene=Scene_Polls.new(@id)
             else
               $scene=@toscene
               end
    end
  end
  
  class Scene_Polls_Results
    def initialize(id,toscene=nil)
      @id=id
      @toscene=toscene
    end
    def main
            begin
              poll=EltenLink::Polls.get(elten_link, @id)
            rescue EltenLink::Error
  alert(_("Error"))
  $scene=@toscene
  $scene=Scene_Polls.new if @toscene==nil
  return
end
@poll=Struct_Polls_Poll.new
@poll.id=@id
@poll.name=poll.name
@poll.author=poll.author
@poll.created = poll.created
@questions=[]
qs=poll.questions
for qu in qs
  q=Struct_Polls_Question.new
  q.question=qu[0]
  q.type=qu[1].to_i
  q.answers=qu[2..-1]
  @questions.push(q)
end
    @poll.description=poll.description
     begin
       results=EltenLink::Polls.results(elten_link, @id, details: 1)
     rescue EltenLink::Error
  alert(_("Error"))
  $scene=@toscene
  $scene=Scene_Polls.new if @toscene==nil
  return
end
@poll.votes=results.votes
@answers=[]
results.answers.each do |answer|
    r=answer.author
  q=answer.question
  a=answer.answer
    ans=Struct_Polls_Answer.new
    ans.question=q
    ans.type=@questions[q].type||2
    a=a.to_i if ans.type<2
  ans.answer=a
  ans.author=r
    @answers.push(ans)
  end
  @filters=[]
  @curanswers=[]
  @form = Form.new([
  @sel_questions = ListBox.new(@questions.map{|q|q.question}, header: p_("Polls", "Questions")),
  @sel_answers = TableBox.new([nil, nil], [], index: 0, header: p_("Polls", "Answers")),
  @sel_filters = ListBox.new([], header: p_("Polls", "Filters")),
  @btn_close = Button.new(_("Close"))
  ])
  @btn_close.on(:press) {@form.resume}
  @sel_questions.on(:move) {
  update_answers
  }
  @sel_questions.trigger(:move)
  @sel_answers.bind_context{|menu|answers_context(menu)}
  @sel_filters.bind_context{|menu|filters_context(menu)}
  @form.cancel_button = @btn_close
  @form.wait
  $scene=@toscene
  $scene=Scene_Polls.new(@id) if @toscene==nil
end
def answers_context(menu)
  return if @sel_answers.rows.size==0
  suc=false
  for f in @filters
    suc=true if f==@sel_questions.index && f==@curanswers[@sel_answers.index]
    end
if suc==false
  menu.option(p_("Polls", "Filter with this answer")) {
  @filters.push([@sel_questions.index, @curanswers[@sel_answers.index], true])
  update_filters
  }
  menu.option(p_("Polls", "Filter without this answer")) {
  @filters.push([@sel_questions.index, @curanswers[@sel_answers.index], false])
  update_filters
  }
else
  menu.option(p_("Polls", "Delete this answer from filters")) {
  for f in @filters
    @filters.delete(f) if f[0]==@sel_questions.index and f[1]==@curanswers[@sel_answers.index]
  end
  update_filters
  }
  end
end
def filters_context(menu)
  return if @filters.size==0
  menu.option(_("Delete"), nil, :del) {
  @filters.delete_at(@sel_filters.index)
  update_filters
  play_sound("editbox_delete")
  @sel_filters.say_option
  }
  end
def update_answers
  authors=@answers.map{|a|a.author}.uniq
  for f in @filters
    for author in authors.deep_dup
if f[2]==true
  suc=false
  for a in @answers
    suc=true if a.author==author && a.question==f[0] && a.answer==f[1]
  end
  authors.delete(author) if suc==false
else
  suc=true
  for a in @answers
    suc=false if a.author==author && a.question==f[0] && a.answer==f[1]
  end
  authors.delete(author) if suc==false
  end
end
end
    q=@questions[@sel_questions.index]
  @sel_answers.rows=[]
  @curanswers=[]
  if q.type<2
    anses=[]
          answersList = []
    for a in @answers
      next if !authors.include?(a.author)
      if a.question==@sel_questions.index
        anses.push(a.answer)
      end
    end
    for a in 0...q.answers.size
      if anses.size>0
      prc=(anses.count(a).to_f/authors.size.to_f*100.0).floor
    else
      prc=0
      end
              answersList.push([q.answers[a], prc, a])
            end
                  answersList = answersList.sort_by {|a| a[1]*-1 }
      answersList.each do |a|
        @sel_answers.rows.push([a[0], a[1].to_s + "%"])
        @curanswers.push(a[2])
      end
  else
    for a in @answers
      next if !authors.include?(a.author)
      if a.question==@sel_questions.index
        @sel_answers.rows.push([a.answer.to_s]) if a.answer.to_s!=""
        @curanswers.push(a.answer)
        end
      end
    end
    @sel_answers.reload
    @sel_answers.index=0
  end
  def update_filters
    @sel_filters.options=[]
    for f in @filters
      q=@questions[f[0]]
      ans=f[1]
      ans=q.answers[f[1]] if q.type<2
      if f[2]==true
        k=p_("Polls", "Includes")
      else
        k=p_("Polls", "Excludes")
        end
      o=q.question+"\r\n"+k+": "+ans
      @sel_filters.options.push(o)
    end
    update_answers
    end
    end
  
class Struct_Polls_Poll
  attr_accessor :id
  attr_accessor :name
  attr_accessor :author
  attr_accessor :description
  attr_accessor :created
  attr_accessor :voted
  attr_accessor :language
  attr_accessor :votes
    def initialize(id=0)
    @id=id
    @name=""
    @author=""
    @description=""
    @created=0
    @voted=false
    @language=""
    @votes=0
  end
end

class Struct_Polls_Question
  attr_accessor :question, :type, :answers
  def initialize
    @question=""
    @type=0
    @answers=[]
  end
end

class Struct_Polls_Answer
  attr_accessor :author, :question, :answer, :type
  def initialize
    @author=""
    @question=0
    @answer=0
    @type=0
    end
  end

# Klangten: the own polls including drafts - edit, publish (for everyone, by
# link only or in a Klango group), withdraw, results and delete.
class Scene_Polls_Mine
  def initialize(lastpoll=0)
    @lastpoll=lastpoll
  end
  def main
    if !Session.logged?
      alert(_("This section is unavailable for guests"))
      $scene=Scene_Polls.new
      return
    end
    @sel=TableBox.new([nil, p_("Polls", "Status"), p_("Polls", "Votes")], [], index: 0, header: p_("Polls", "My polls and drafts"))
    @sel.bind_context{|menu|context(menu)}
    return if !refresh
    @sel.focus
    loop do
      loop_update
      @sel.update
      $scene=Scene_Polls.new if key_pressed?(:key_escape)
      if key_pressed?(:key_enter) && @polls.size>0
        poll=@polls[@sel.index]
        actions=actions_for(poll)
        actions[:cancel]=_("Cancel")
        action=select_action(actions, header: poll.name, cancel: :cancel, flags: 1)
        run(action, poll)
        @sel.focus if $scene==self
      end
      break if $scene!=self
    end
  end
  def status_label(poll)
    case poll.status
    when "draft" then p_("Polls", "draft")
    when "group" then p_("Polls", "in a group")
    when "hidden" then p_("Polls", "only with the link")
    else p_("Polls", "public")
    end
  end
  def refresh
    begin
      @polls=EltenLink::Polls.by_me(elten_link)
    rescue EltenLink::Error
      alert(_("Error"))
      $scene=Scene_Polls.new
      return false
    end
    index=@polls.index{|p|p.id==@lastpoll} || [@sel.index, 0].max
    @sel.rows=@polls.map{|p|[p.name, status_label(p), p.votes.to_s]}
    @sel.reload
    @sel.index=[[index, @polls.size-1].min, 0].max
    true
  end
  def actions_for(poll)
    actions={}
    actions[:edit]=p_("Polls", "Edit")
    if poll.draft?
      actions[:publish]=p_("Polls", "Publish")
    else
      actions[:unpublish]=p_("Polls", "Withdraw (make it a draft again)")
    end
    actions[:results]=p_("Polls", "Show results")
    actions[:report]=p_("Polls", "Show report")
    actions[:delete]=_("Delete")
    actions
  end
  def context(menu)
    if @polls!=nil && @polls.size>0
      poll=@polls[@sel.index]
      actions_for(poll).each do |key, label|
        shortcut={:edit=>"e", :delete=>:del, :results=>"t", :report=>"p"}[key]
        menu.option(label, nil, shortcut || "") { run(key, poll) }
      end
    end
    menu.option(p_("Polls", "New poll"), nil, "n") { $scene=Scene_Polls_Create.new(nil, Scene_Polls_Mine.new) }
    menu.option(_("Refresh"), nil, "r") { refresh; @sel.focus }
  end
  def run(action, poll)
    @lastpoll=poll.id
    case action
    when :edit
      begin
        details=EltenLink::Polls.get(elten_link, poll.id)
      rescue EltenLink::Error
        return alert(_("Error"))
      end
      $scene=Scene_Polls_Create.new(details, Scene_Polls_Mine.new(poll.id))
    when :publish then publish(poll)
    when :unpublish
      return if !confirm(p_("Polls", "Do you want to withdraw %{name}? Nobody can vote until you publish it again.")%{:name=>poll.name})
      begin
        EltenLink::Polls.unpublish(elten_link, poll)
      rescue EltenLink::Error
        return alert(_("Error"))
      end
      alert(p_("Polls", "The poll is a draft again."))
      refresh
    when :results then $scene=Scene_Polls_Results.new(poll.id, Scene_Polls_Mine.new(poll.id))
    when :report then $scene=Scene_Polls_Report.new(poll.id, Scene_Polls_Mine.new(poll.id))
    when :delete
      return if !confirm(p_("Polls", "Do you really want to delete %{name}?")%{:name=>poll.name})
      begin
        EltenLink::Polls.delete(elten_link, poll)
      rescue EltenLink::Error
        return alert(_("Error"))
      end
      alert(p_("Polls", "deleted"))
      refresh
    end
  end
  def publish(poll)
    groups=[]
    begin
      groups=EltenLink::Community.groups(elten_link)
    rescue EltenLink::Error => e
      Log.warning("Poll groups failed: #{e.message}")
    end
    labels=[p_("Polls", "For everyone"), p_("Polls", "Only for people with the link")]+groups.map{|g|p_("Polls", "For the members of %{group}")%{:group=>g.name}}
    index=selector(labels, header: p_("Polls", "Publish %{name}")%{:name=>poll.name}, start_index: 0, cancel_index: -1)
    return if index==nil || index<0
    group=index>=2 ? groups[index-2] : nil
    begin
      EltenLink::Polls.publish(elten_link, poll, groupid: group ? group.id : nil, hidden: index==1)
    rescue EltenLink::Error => e
      return alert(e.message.to_s!="" ? e.message.to_s : _("Error"))
    end
    alert(p_("Polls", "The poll has been published."))
    refresh
  end
end
