const TelegramBot = require('node-telegram-bot-api');
const path = require('path');
const fs = require('fs');

let bot = null;
let botConfig = {};
let db = null;
let services = {
    getCameraStatus: () => ({}),
    getDiskUsage: () => ({}),
    restartSystem: () => {},
    cleanupRecordings: () => {},
    getRtspTemplates: () => ({}),
    generateRtspUrl: () => null,
    updateAdminCredentials: () => ({ success: false })
};

// Store user states for multi-step interactions
const userStates = {};

/**
 * Initialize the Telegram Bot
 * @param {Object} config - The application configuration object
 * @param {Object} database - The SQLite database instance
 * @param {Object} serviceProvider - Object containing service functions
 */
function init(config, database, serviceProvider) {
    if (!config.telegram || !config.telegram.enabled || !config.telegram.bot_token) {
        console.log('[Telegram] Bot disabled or token missing.');
        return;
    }

    botConfig = config.telegram;
    db = database;
    
    if (serviceProvider) {
        // Handle legacy function argument or new object
        if (typeof serviceProvider === 'function') {
            services.getCameraStatus = serviceProvider;
        } else {
            services = { ...services, ...serviceProvider };
        }
    }

    // Initialize bot with polling (no webhook needed, works behind firewall)
    try {
        bot = new TelegramBot(botConfig.bot_token, { polling: true });
        console.log('[Telegram] Bot started in polling mode.');

        // Set commands
        bot.setMyCommands([
            { command: '/start', description: 'Menu Utama' },
            { command: '/password', description: 'Ganti Password Admin' },
            { command: '/help', description: 'Bantuan' }
        ]);

        setupListeners();
    } catch (error) {
        console.error('[Telegram] Failed to start bot:', error.message);
    }
}

function stop() {
    if (bot) {
        try {
            bot.stopPolling();
        } catch (e) {
            console.error('[Telegram] stopPolling error:', e.message);
        }
        bot = null;
    }
}

function restart(config, database, serviceProvider) {
    stop();
    init(config, database, serviceProvider);
}
/**
 * Send a message to the configured chat_id
 * @param {string} text - The message text (HTML supported)
 */
function sendMessage(text) {
    if (!bot || !botConfig.chat_id) return;
    
    // Split long messages if needed (Telegram limit is 4096 chars)
    const MAX_LENGTH = 4000;
    if (text.length > MAX_LENGTH) {
        const chunks = text.match(new RegExp(`.{1,${MAX_LENGTH}}`, 'g'));
        chunks.forEach(chunk => {
            bot.sendMessage(botConfig.chat_id, chunk, { parse_mode: 'HTML' })
                .catch(err => console.error('[Telegram] Send error:', err.message));
        });
    } else {
        bot.sendMessage(botConfig.chat_id, text, { parse_mode: 'HTML' })
            .catch(err => console.error('[Telegram] Send error:', err.message));
    }
}

function isAdmin(chatId) {
    if (!botConfig.chat_id) return true; 
    return String(chatId) === String(botConfig.chat_id);
}

function getMainKeyboard() {
    return {
        inline_keyboard: [
            [
                { text: '📷 Status Kamera', callback_data: 'status' },
                { text: '💾 Disk Usage', callback_data: 'disk' }
            ],
            [
                { text: '📼 Rekaman Terbaru', callback_data: 'recordings' },
                { text: '🔗 Generate RTSP', callback_data: 'rtsp_menu' }
            ],
            [
                { text: '🧹 Cleanup', callback_data: 'clean_menu' },
                { text: '🔄 Restart', callback_data: 'restart' }
            ]
        ]
    };
}

function setupListeners() {
    // Handle Callback Queries (Button Clicks)
    bot.on('callback_query', async (query) => {
        const chatId = query.message.chat.id;
        const data = query.data;
        const msgId = query.message.message_id;

        if (!isAdmin(chatId)) {
            bot.answerCallbackQuery(query.id, { text: '⛔ Akses Ditolak', show_alert: true });
            return;
        }

        // --- Navigation Logic ---
        if (data === 'main_menu') {
            bot.editMessageText('🤖 <b>Menu Utama CCTV Monitor</b>\nSilakan pilih menu di bawah:', {
                chat_id: chatId,
                message_id: msgId,
                parse_mode: 'HTML',
                reply_markup: getMainKeyboard()
            });
        }
        
        // --- Feature: Status ---
        else if (data === 'status') {
            const status = services.getCameraStatus();
            let report = '<b>📹 Status Kamera CCTV</b>\n\n';
            
            if (status && Object.keys(status).length > 0) {
                db.all("SELECT id, nama, lokasi FROM cameras", [], (err, rows) => {
                    if (err) {
                        bot.answerCallbackQuery(query.id, { text: 'Database Error' });
                        return;
                    }
                    
                    let onlineCount = 0;
                    rows.forEach(cam => {
                        const camStatus = status[cam.id];
                        if (camStatus) {
                            const icon = camStatus.online ? '✅' : '🔴';
                            report += `${icon} <b>${cam.nama}</b>\n`;
                            if (camStatus.online) onlineCount++;
                        }
                    });
                    report += `\nTotal: ${rows.length} | Online: ${onlineCount}`;
                    
                    bot.editMessageText(report, {
                        chat_id: chatId,
                        message_id: msgId,
                        parse_mode: 'HTML',
                        reply_markup: {
                            inline_keyboard: [[{ text: '🔙 Kembali', callback_data: 'main_menu' }]]
                        }
                    });
                });
            } else {
                bot.editMessageText('⚠️ Data status belum tersedia.', {
                    chat_id: chatId,
                    message_id: msgId,
                    reply_markup: { inline_keyboard: [[{ text: '🔙 Kembali', callback_data: 'main_menu' }]] }
                });
            }
        }

        // --- Feature: Disk ---
        else if (data === 'disk') {
            const disk = services.getDiskUsage();
            let report = `<b>💾 Status Penyimpanan</b>\n\n`;
            if (disk && disk.total) {
                report += `Total: <b>${disk.total}</b>\n`;
                report += `Terpakai: <b>${disk.used}</b> (${disk.percent}%)\n`;
                report += `Sisa: <b>${disk.free}</b>\n`;
            } else {
                report += 'Data tidak tersedia.';
            }

            bot.editMessageText(report, {
                chat_id: chatId,
                message_id: msgId,
                parse_mode: 'HTML',
                reply_markup: { inline_keyboard: [[{ text: '🔙 Kembali', callback_data: 'main_menu' }]] }
            });
        }

        // --- Feature: Recordings ---
        else if (data === 'recordings') {
             const querySql = `SELECT r.*, c.nama as camera_name FROM recordings r JOIN cameras c ON r.camera_id = c.id ORDER BY r.created_at DESC LIMIT 5`;
             db.all(querySql, [], (err, rows) => {
                 let response = '<b>📼 5 Rekaman Terakhir</b>\n\n';
                 if (!err && rows.length > 0) {
                     rows.forEach(row => {
                         const date = new Date(row.created_at).toLocaleString('id-ID');
                         const size = (row.size / 1024 / 1024).toFixed(2) + ' MB';
                         response += `📹 <b>${row.camera_name}</b>\n🕒 ${date}\n💾 ${size}\n\n`;
                     });
                 } else {
                     response += 'Belum ada data rekaman.';
                 }

                 bot.editMessageText(response, {
                     chat_id: chatId,
                     message_id: msgId,
                     parse_mode: 'HTML',
                     reply_markup: { inline_keyboard: [[{ text: '🔙 Kembali', callback_data: 'main_menu' }]] }
                 });
             });
        }

        // --- Feature: Restart ---
        else if (data === 'restart') {
            bot.editMessageText('⚠️ <b>Konfirmasi Restart</b>\nApakah Anda yakin ingin me-restart sistem?', {
                chat_id: chatId,
                message_id: msgId,
                parse_mode: 'HTML',
                reply_markup: {
                    inline_keyboard: [
                        [
                            { text: '✅ Ya, Restart', callback_data: 'do_restart' },
                            { text: '❌ Batal', callback_data: 'main_menu' }
                        ]
                    ]
                }
            });
        }
        else if (data === 'do_restart') {
            bot.answerCallbackQuery(query.id, { text: 'Memulai ulang sistem...' });
            bot.sendMessage(chatId, '🔄 Sistem sedang direstart...');
            setTimeout(() => services.restartSystem(), 1000);
        }

        // --- Feature: Clean Menu ---
        else if (data === 'clean_menu') {
            bot.editMessageText('<b>🧹 Menu Pembersihan</b>\nPilih opsi pembersihan:', {
                chat_id: chatId,
                message_id: msgId,
                parse_mode: 'HTML',
                reply_markup: {
                    inline_keyboard: [
                        [{ text: '🗑️ Hapus Orphans (File Hilang)', callback_data: 'clean_orphans' }],
                        [{ text: '📅 Hapus > 7 Hari', callback_data: 'clean_old_7' }],
                        [{ text: '📅 Hapus > 30 Hari', callback_data: 'clean_old_30' }],
                        [{ text: '🔙 Kembali', callback_data: 'main_menu' }]
                    ]
                }
            });
        }
        else if (data === 'clean_orphans') {
            bot.answerCallbackQuery(query.id, { text: 'Membersihkan orphans...' });
            services.cleanupRecordings('orphans', null, (result) => {
                bot.sendMessage(chatId, `✅ Pembersihan selesai. ${result.deleted} data dihapus.`);
            });
        }
        else if (data.startsWith('clean_old_')) {
            const days = parseInt(data.replace('clean_old_', ''));
            bot.answerCallbackQuery(query.id, { text: `Menghapus data > ${days} hari...` });
            services.cleanupRecordings('old', days, (result) => {
                bot.sendMessage(chatId, `✅ Selesai. ${result.deleted} rekaman dihapus (${result.freedSpace}).`);
            });
        }

        // --- Feature: RTSP Generator Menu ---
        else if (data === 'rtsp_menu') {
            const templates = services.getRtspTemplates();
            const brands = Object.keys(templates);
            
            // Create keyboard with brands (2 columns)
            const keyboard = [];
            let row = [];
            brands.forEach((brand, index) => {
                row.push({ text: templates[brand].name, callback_data: `rtsp_brand_${brand}` });
                if (row.length === 2 || index === brands.length - 1) {
                    keyboard.push(row);
                    row = [];
                }
            });
            keyboard.push([{ text: '🔙 Kembali', callback_data: 'main_menu' }]);

            bot.editMessageText('<b>🔗 Generator RTSP URL</b>\nPilih merek kamera:', {
                chat_id: chatId,
                message_id: msgId,
                parse_mode: 'HTML',
                reply_markup: { inline_keyboard: keyboard }
            });
        }
        
        // --- Feature: RTSP Steps ---
        else if (data.startsWith('rtsp_brand_')) {
            const brand = data.replace('rtsp_brand_', '');
            userStates[chatId] = { step: 'ask_ip', brand: brand };
            
            bot.sendMessage(chatId, `<b>Langkah 1/3:</b>\nMasukkan IP Address kamera (contoh: 192.168.1.100):`, { 
                parse_mode: 'HTML',
                reply_markup: { force_reply: true }
            });
            bot.answerCallbackQuery(query.id);
        }

        // Always answer callback to stop loading animation
        try {
            await bot.answerCallbackQuery(query.id);
        } catch(e) {}
    });

    // Handle Text Messages (for Inputs)
    bot.on('message', (msg) => {
        const chatId = msg.chat.id;
        const text = msg.text;

        if (!userStates[chatId]) return;

        const state = userStates[chatId];
        
        // --- RTSP Flow ---
        if (state.step === 'ask_ip') {
            state.ip = text.trim();
            state.step = 'ask_user';
            bot.sendMessage(chatId, `<b>Langkah 2/3:</b>\nMasukkan Username kamera (biasanya admin):`, { 
                parse_mode: 'HTML',
                reply_markup: { force_reply: true }
            });
        }
        else if (state.step === 'ask_user') {
            state.username = text.trim();
            state.step = 'ask_pass';
            bot.sendMessage(chatId, `<b>Langkah 3/3:</b>\nMasukkan Password kamera:`, { 
                parse_mode: 'HTML',
                reply_markup: { force_reply: true }
            });
        }
        else if (state.step === 'ask_pass') {
            state.password = text.trim();
            
            // Generate URL
            const url = services.generateRtspUrl(state.brand, {
                ip: state.ip,
                username: state.username,
                password: state.password
            });

            if (url) {
                bot.sendMessage(chatId, `✅ <b>RTSP URL Berhasil Dibuat:</b>\n\n<code>${url}</code>\n\nSalin URL di atas ke konfigurasi kamera.`, { 
                    parse_mode: 'HTML',
                    reply_markup: getMainKeyboard()
                });
            } else {
                bot.sendMessage(chatId, '❌ Gagal membuat URL. Coba lagi.', { reply_markup: getMainKeyboard() });
            }
            
            delete userStates[chatId];
        }

        // --- Change Password Flow ---
        else if (state.step === 'ask_new_username') {
            state.username = text.trim();
            if (state.username.length < 3) {
                bot.sendMessage(chatId, '❌ Username minimal 3 karakter. Silakan input ulang:');
                return;
            }
            state.step = 'ask_new_password';
            bot.sendMessage(chatId, `<b>Langkah 2/2:</b>\nMasukkan Password baru untuk admin:`, { 
                parse_mode: 'HTML',
                reply_markup: { force_reply: true }
            });
        }
        else if (state.step === 'ask_new_password') {
            state.password = text.trim();
            if (state.password.length < 4) {
                bot.sendMessage(chatId, '❌ Password minimal 4 karakter. Silakan input ulang:');
                return;
            }

            const result = services.updateAdminCredentials(state.username, state.password);
            
            if (result.success) {
                bot.sendMessage(chatId, `✅ <b>Sukses!</b>\nCredential admin berhasil diperbarui.\n\n👤 Username: <code>${state.username}</code>\n🔑 Password: <code>${state.password}</code>`, { 
                    parse_mode: 'HTML',
                    reply_markup: getMainKeyboard()
                });
            } else {
                bot.sendMessage(chatId, `❌ Gagal memperbarui credential: ${result.error}`, { reply_markup: getMainKeyboard() });
            }
            
            delete userStates[chatId];
        }
    });

    // /password - Change Admin Credentials
    bot.onText(/\/password/, (msg) => {
        const chatId = msg.chat.id;
        if (!isAdmin(chatId)) {
            bot.sendMessage(chatId, '⛔ Perintah ini hanya untuk Admin.');
            return;
        }

        userStates[chatId] = { step: 'ask_new_username' };
        bot.sendMessage(chatId, `⚠️ <b>Ganti Password Admin Web</b>\n\n<b>Langkah 1/2:</b>\nMasukkan Username baru:`, { 
            parse_mode: 'HTML',
            reply_markup: { force_reply: true }
        });
    });

    // /start - Main Entry Point
    bot.onText(/\/start/, (msg) => {
        const chatId = msg.chat.id;
        const username = msg.from.username ? `@${msg.from.username}` : msg.from.first_name;
        
        if (isAdmin(chatId)) {
            bot.sendMessage(chatId, `Halo <b>${username}</b>! 👋\nSelamat datang di Panel Kontrol CCTV.`, {
                parse_mode: 'HTML',
                reply_markup: getMainKeyboard()
            });
        } else {
            bot.sendMessage(chatId, `⚠️ <b>Akses Ditolak</b>\nID Chat Anda: <code>${chatId}</code>\nAnda belum terdaftar sebagai Admin.`, { parse_mode: 'HTML' });
        }
    });

    // Keep /help text command
    bot.onText(/\/help/, (msg) => {
        const chatId = msg.chat.id;
        bot.sendMessage(chatId, 'ℹ️ <b>Bantuan</b>\nGunakan perintah /start untuk membuka menu utama interaktif.', { parse_mode: 'HTML' });
    });
}

module.exports = {
    init,
    sendMessage,
    stop,
    restart
};
