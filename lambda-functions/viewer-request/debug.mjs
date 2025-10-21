import { handler } from './index.mjs';

// Test cases for resize-req-at-edge Lambda function
const testCases = [
    {
        name: 'WebP support - with dimension parameter',
        event: {
            Records: [{
                cf: {
                    request: {
                        uri: '/blog/posts/2024/04/19/cover.jpg',
                        querystring: 'd=300x300',
                        headers: {
                            accept: [{
                                value: 'text/html,image/webp,image/apng,*/*'
                            }]
                        }
                    }
                }
            }]
        }
    },
    {
        name: 'No WebP support - with dimension parameter',
        event: {
            Records: [{
                cf: {
                    request: {
                        uri: '/image/test.png',
                        querystring: 'd=200x200',
                        headers: {
                            accept: [{
                                value: 'text/html,image/apng,*/*'
                            }]
                        }
                    }
                }
            }]
        }
    },
    {
        name: 'No dimension parameter - should return original request',
        event: {
            Records: [{
                cf: {
                    request: {
                        uri: '/image/test.png',
                        querystring: '',
                        headers: {
                            accept: [{
                                value: 'text/html,image/webp,*/*'
                            }]
                        }
                    }
                }
            }]
        }
    },
    {
        name: 'Invalid dimension parameter - should return original request',
        event: {
            Records: [{
                cf: {
                    request: {
                        uri: '/image/test.png',
                        querystring: 'd=invalid',
                        headers: {
                            accept: [{
                                value: 'text/html,image/webp,*/*'
                            }]
                        }
                    }
                }
            }]
        }
    },
    {
        name: 'Complex path with WebP support',
        event: {
            Records: [{
                cf: {
                    request: {
                        uri: '/assets/images/gallery/photo-001.jpg',
                        querystring: 'd=800x600',
                        headers: {
                            accept: [{
                                value: 'image/webp,image/apng,image/*,*/*'
                            }]
                        }
                    }
                }
            }]
        }
    }
];

console.log('Testing resize-req-at-edge Lambda function...\n');

for (const testCase of testCases) {
    console.log(`Test: ${testCase.name}`);
    console.log('Input URI:', testCase.event.Records[0].cf.request.uri);
    console.log('Query string:', testCase.event.Records[0].cf.request.querystring);
    console.log('Accept header:', testCase.event.Records[0].cf.request.headers.accept?.[0]?.value || 'none');

    try {
        const result = await handler(testCase.event);
        console.log('Output URI:', result.uri);
    } catch (error) {
        console.error('Error:', error.message);
    }

    console.log('---\n');
}

console.log('All tests completed.');
