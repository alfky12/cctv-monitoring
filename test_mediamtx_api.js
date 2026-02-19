const http = require('http');
const config = require('./config.json');

function getEffectiveMediaMtxHost() {
    const host = config.mediamtx?.host || '127.0.0.1';
    if (host === 'auto') {
        return '127.0.0.1';
    }
    return host;
}

function mediaMtxRequest(method, path) {
    return new Promise((resolve, reject) => {
        const options = {
            hostname: getEffectiveMediaMtxHost(),
            port: config.mediamtx?.api_port || 9123,
            path: path.startsWith('/v3/') ? path : '/v3/config/paths' + path,
            method: method,
            headers: {
                'Content-Type': 'application/json'
            }
        };

        console.log(`Requesting ${method} http://${options.hostname}:${options.port}${options.path}`);

        const req = http.request(options, (res) => {
            let data = '';
            res.on('data', (chunk) => data += chunk);
            res.on('end', () => {
                console.log(`Status Code: ${res.statusCode}`);
                if (res.statusCode >= 200 && res.statusCode < 300) {
                    try {
                        const json = data ? JSON.parse(data) : {};
                        console.log('Response:', JSON.stringify(json, null, 2));
                        resolve(json);
                    } catch (parseErr) {
                        console.error('JSON Parse Error:', parseErr.message);
                        console.log('Raw Data:', data);
                        resolve({ error: true, message: 'Invalid JSON' });
                    }
                } else {
                    console.log('Error Response:', data);
                    resolve({ error: true, status: res.statusCode, message: data });
                }
            });
        });

        req.on('error', (e) => {
            console.error(`Request Error: ${e.message}`);
            resolve({ error: true, message: e.message });
        });

        req.end();
    });
}

async function test() {
    const pathsData = await mediaMtxRequest('GET', '/v3/paths/list');
    
    if (pathsData.items) {
        console.log(`Found ${pathsData.items.length} items.`);
        pathsData.items.forEach(item => {
            console.log(`- Name: ${item.name}`);
            console.log(`  Ready: ${item.ready}`);
            console.log(`  Source: ${item.source}`);
            console.log(`  SourceReady: ${item.sourceReady}`); // Check if this property exists
            console.log('---');
        });
    } else {
        console.log('No items found or invalid structure.');
    }
}

test();
