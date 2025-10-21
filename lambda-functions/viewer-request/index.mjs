'use strict';

export const handler = async (event) => {
    const request = event.Records[0].cf.request;

    // Early return if no dimension parameter
    const params = new URLSearchParams(request.querystring);
    if (!params.has('d')) {
        return request;
    }

    // Parse URI once with more efficient regex
    const uriMatch = request.uri.match(/\/(.+)\/([^/]+)\.([^.]+)$/);
    if (!uriMatch) {
        return request;
    }

    const [, path, filename, extension] = uriMatch;

    // Parse dimension parameter
    const dimension = params.get('d').split('x');
    if (dimension.length !== 2) {
        return request;
    }

    // Check WebP support efficiently
    const acceptHeader = request.headers['accept']?.[0]?.value;
    const format = acceptHeader?.includes('webp') ? 'webp' : extension;

    // Build optimized URI
    request.uri = `/resize/${path}/${dimension[0]}x${dimension[1]}/${format}/${filename}.${extension}`;

    console.log(request.uri);

    return request;
};
