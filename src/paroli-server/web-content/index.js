var ws;
var ttsSocketURL = (window.location.toString().replace('http', 'ws') + 'api/v1/stream');
var pcmplayer_opt = {
     encoding: '16bitInt',
     channels: 1,
     sampleRate: 22050,
     flushingTime: 100
}
var player;

window.onload = function () {
    const languageNames = {
        pt_br: 'Portuguese (Brazil)',
        en_us: 'English (US)',
        zh_cn: 'Chinese (Mandarin)',
        de_de: 'German',
        fr_fr: 'French'
    }
    let languageList = document.getElementById('language_select')
    fetch('/api/v1/languages').then(function (response) {
        return response.json();
    }).then(function (data) {
        data.languages.forEach(function (language) {
            let option = document.createElement('option')
            option.value = language
            option.text = languageNames[language] || language
            languageList.appendChild(option)
        })
        languageList.value = data.active
    }).catch(function (error) {
        console.error('Unable to load languages', error)
    })
    let speaker_list = document.getElementById('speaker_select')
    fetch('/api/v1/speakers').then(function (response) {
        return response.json();
    }).then(function (data) {
        let default_speaker = null
        // Single-speaker models do not need a second selector.
        if(Object.keys(data).length == 0) {
            document.getElementById('speaker_controls').style.display = 'none'
            return
        }
        for(let key in data) {
            let option = document.createElement('option')
            option.value = data[key]
            option.text = key
            speaker_list.appendChild(option)

            if(data[key] == 0) {
                default_speaker = data[key]
            }
        }
        speaker_list.value = default_speaker
    });
}

function runTTS() {
    let str = document.getElementById('txt_input').value
    let speaker = document.getElementById('speaker_select').value
    let language = document.getElementById('language_select').value
    let data = JSON.stringify({
        text: str,
        language: language,
        speaker_id: parseInt(speaker),
        audio_format: 'pcm'
    })
    if (ws == null || ws.readyState != 1) {
        player = new PCMPlayer(pcmplayer_opt);
        reconnectWS(function () {
            ws.send(data);
        });
        return;
    }

    ws.send(data);
}

function reconnectWS(connect_fn) {
     if (ws) ws.close()

     ws = new WebSocket(ttsSocketURL);
     ws.binaryType = 'arraybuffer';
     ws.addEventListener('open', function (event) {
          connect_fn && connect_fn()
     });
     ws.addEventListener('message', function (event) {

          if(typeof event.data == 'string') {
              let msg = JSON.parse(event.data);
              if(msg["status"] == "ok")
                  return;
              console.error(msg);
          }
          var data = new Uint8Array(event.data);
          if(data.length == 0) return; // ignore empty (pong) messages
          player.feed(data);
     });
}
