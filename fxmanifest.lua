fx_version 'cerulean'
game 'gta5'
lua54 'yes'

description 'DaGarage | ESX and QBCore garages'
version '1.0.0'

shared_scripts { 'config.lua', 'locale.lua', 'framework.lua' }
client_script 'client.lua'
server_scripts { '@oxmysql/lib/MySQL.lua', 'server.lua' }

ui_page 'ui/index.html'
files { 'ui/index.html', 'ui/style.css', 'ui/app.js' }

dependencies {
    '/onesync',
    'oxmysql',
    'DaTuning'
}
