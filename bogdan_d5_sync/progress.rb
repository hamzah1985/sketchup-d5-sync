# SPDX-License-Identifier: GPL-3.0-or-later
require 'json'
module BogdanD5Sync
  module Progress
    def self.show(message = 'Connecting to D5')
      @message = message
      if @dialog
        @dialog.show
        update(message)
        return
      end
      style = defined?(UI::HtmlDialog::STYLE_UTILITY) ? UI::HtmlDialog::STYLE_UTILITY : UI::HtmlDialog::STYLE_DIALOG
      @dialog = UI::HtmlDialog.new(:dialog_title=>'D5 Sync Progress', :width=>360,
        :height=>210, :resizable=>false, :style=>style)
      @dialog.set_file(File.join(__dir__, 'progress.html'))
      @dialog.add_action_callback('ready') { |_context| update(@message) }
      @dialog.add_action_callback('disconnect') { |_context| BogdanD5Sync.controller.stop }
      @dialog.set_on_closed { @dialog = nil }
      @dialog.show
    end
    def self.update(message)
      @message = message
      @dialog.execute_script('setStage(' + JSON.generate(message) + ')') if @dialog
      @revision = (@revision || 0) + 1
      revision = @revision
      dialog = @dialog
      if dialog && message.start_with?('Model sent')
        UI.start_timer(1.5, false) do
          # A fresh update must not be hidden by a previous completion timer.
          dialog.close if @dialog.equal?(dialog) && @revision == revision
        end
      end
    end
  end
end
