import { handler } from './index.mjs';

// Sample CloudFront origin response event
// This simulates a 404 response when a resized image doesn't exist
const event = {
    Records: [
        {
            cf: {
                request: {
                    uri: '/resize/blog/posts/2024/04/19/300x300/webp/cover.jpg',
                },
                response: {
                    status: '404',
                    statusDescription: 'Not Found',
                    headers: {},
                },
            },
        },
    ],
};

console.log('Testing resize-res-at-edge Lambda function...');
console.log('Event:', JSON.stringify(event, null, 2));
console.log('---');

try {
    const result = await handler(event);
    console.log('Result status:', result.status);
    console.log('Result headers:', JSON.stringify(result.headers, null, 2));

    if (result.body) {
        console.log('Body encoding:', result.bodyEncoding);
        console.log('Body length:', result.body.length, 'characters');
        console.log('(Base64 encoded image data)');
    } else {
        console.log('No body returned');
    }
} catch (error) {
    console.error('Error:', error);
    process.exit(1);
}
