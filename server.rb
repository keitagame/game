require 'em-websocket'
require 'json'

# --- 1. HTTPサーバリクエスト処理 (index.htmlを配信) ---
class HttpHandler < EM::Connection
  def receive_data(data)
    if data =~ /^GET /
      file_path = File.join(__dir__, 'index.html')
      if File.exist?(file_path)
        content = File.read(file_path)
        response = [
          "HTTP/1.1 200 OK",
          "Content-Type: text/html; charset=utf-8",
          "Content-Length: #{content.bytesize}",
          "Connection: close",
          "",
          content
        ].join("\r\n")
        send_data response
      else
        send_data "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
      end
    end
    close_connection_after_writing
  end
end

# --- 2. ゲーム状態管理 ---
clients = {}
game = {
  phase: 'lobby', # 'lobby', 'prompt', 'answer', 'game_over'
  round: 0,
  prompt: '',
  prompt_giver_id: nil
}

def broadcast(clients, data)
  msg = data.to_json
  clients.keys.each { |ws| ws.send(msg) }
end

def state_payload(clients, game, log_msg = '')
  {
    type: 'state',
    phase: game[:phase],
    round: game[:round],
    prompt: game[:prompt],
    prompt_giver_id: game[:prompt_giver_id],
    log: log_msg,
    players: clients.values.map do |p|
      { id: p[:id], name: p[:name], score: p[:score], active: p[:active], answered: !p[:answer].nil? }
    end
  }
end

# --- 3. イベントループ起動 ---
EM.run do
  # HTTP サーバ起動 (ポート 8000)
  EM.start_server "0.0.0.0", 8000, HttpHandler
  puts "HTTP サーバが起動しました: http://localhost:8000/"

  # WebSocket サーバ起動 (ポート 8080)
  EM::WebSocket.run(host: "0.0.0.0", port: 8000) do |ws|
    ws.onopen do
      clients[ws] = { id: ws.object_id, name: '', score: 0, active: true, answer: nil }
      ws.send({ type: 'init', id: ws.object_id }.to_json)
    end

    ws.onmessage do |msg|
      data = JSON.parse(msg)
      player = clients[ws]
      next unless player

      case data['action']
      when 'join'
        player[:name] = data['name'].to_s.strip
        player[:name] = "Player_#{player[:id] % 1000}" if player[:name].empty?
        broadcast(clients, state_payload(clients, game, "#{player[:name]} が参加しました。"))

      when 'start'
        if game[:phase] == 'lobby' && clients.values.count { |p| !p[:name].empty? } >= 2
          clients.values.each { |p| p[:score] = 0; p[:active] = !p[:name].empty?; p[:answer] = nil }
          game[:round] = 1
          game[:phase] = 'prompt'
          actives = clients.values.select { |p| p[:active] }
          game[:prompt_giver_id] = actives.first[:id]
          broadcast(clients, state_payload(clients, game, "ゲームを開始します！第1ラウンド開始。"))
        end

      when 'submit_prompt'
        if game[:phase] == 'prompt' && player[:id] == game[:prompt_giver_id]
          game[:prompt] = data['prompt'].to_s
          game[:phase] = 'answer'
          clients.values.each { |p| p[:answer] = nil }
          broadcast(clients, state_payload(clients, game, "お題: 「#{game[:prompt]}」 が設定されました！回答を入力してください。"))
        end

      when 'submit_answer'
        if game[:phase] == 'answer' && player[:active] && player[:answer].nil?
          player[:answer] = data['answer'].to_s.strip
          broadcast(clients, state_payload(clients, game, "#{player[:name]} が回答を送信しました。"))

          actives = clients.values.select { |p| p[:active] }
          if actives.all? { |p| !p[:answer].nil? }
            # 集計 & ポイント付与（被り判定）
            counts = Hash.new(0)
            actives.each { |p| counts[p[:answer].downcase] += 1 }

            scored_players = []
            actives.each do |p|
              if counts[p[:answer].downcase] >= 2
                p[:score] += 1
                scored_players << p[:name]
              end
            end

            log = "【結果発表】\n"
            actives.each { |p| log += "・#{p[:name]}: 「#{p[:answer]}」\n" }
            log += scored_players.empty? ? "一致した人はいませんでした。\n" : "一致してポイント獲得(+1pt): #{scored_players.join(', ')}\n"

            # 5ラウンドごとに最下位脱落
            if game[:round] % 5 == 0 && actives.size > 1
              min_score = actives.map { |p| p[:score] }.min
              lowest = actives.select { |p| p[:score] == min_score }
              if lowest.size < actives.size
                lowest.each { |p| p[:active] = false }
                log += "【脱落】5ラウンド経過！最下位の #{lowest.map{|p| p[:name]}.join(', ')} が脱落しました。\n"
              end
            end

            # 勝敗判定
            remaining = clients.values.select { |p| p[:active] }
            if remaining.size <= 1
              game[:phase] = 'game_over'
              winner = remaining.first ? remaining.first[:name] : '該当者なし'
              log += "\n【ゲーム終了】独り勝ち者: #{winner}！"
            else
              game[:round] += 1
              game[:phase] = 'prompt'
              next_giver = remaining[(game[:round] - 1) % remaining.size]
              game[:prompt_giver_id] = next_giver[:id]
              game[:prompt] = ''
            end

            broadcast(clients, state_payload(clients, game, log))
          end
        end
      end
    end

    ws.onclose do
      clients.delete(ws)
      broadcast(clients, state_payload(clients, game, "プレイヤーが切断しました。"))
    end
  end
  puts "WebSocket サーバが起動しました: ws://localhost:8080/"
end
