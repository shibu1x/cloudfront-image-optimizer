'use strict';

import {
    S3Client,
    GetObjectCommand,
    PutObjectCommand
} from '@aws-sdk/client-s3';
import sharp from 'sharp';

// Constants
const KEY_PATTERN = /^resize\/(.+)\/(\d+)x(\d+)\/([^/]+)\/(.+)$/;
const BUCKET = '__S3_BUCKET_PLACEHOLDER__';
const REGION = 'ap-northeast-1';
const MAX_DIMENSION = 4000;
const CACHE_CONTROL = 'max-age=86400';

// S3 client will be initialized lazily
let s3Client;

export const handler = async (event) => {
    // Initialize S3 client on first invocation
    if (!s3Client) {
        s3Client = new S3Client({ region: REGION });
    }

    const { request, response } = event.Records[0].cf;

    // Early return if image exists
    if (response.status !== '404' && response.status !== '403') {
        return response;
    }

    const key = request.uri.substring(1);

    console.log('Not Found. key:', key);

    // Parse and validate key format
    const keyMatch = key.match(KEY_PATTERN);
    if (!keyMatch) {
        console.log('Invalid key format');
        return response;
    }

    const [, subpath, widthStr, heightStr, format, filename] = keyMatch;
    const width = parseInt(widthStr, 10);
    const height = parseInt(heightStr, 10);

    // Validate dimensions
    if (width <= 0 || height <= 0 || width > MAX_DIMENSION || height > MAX_DIMENSION) {
        console.log('Invalid dimensions:', width, height);
        return response;
    }

    // Correct format for Sharp (jpg -> jpeg)
    const sharpFormat = format === 'jpg' ? 'jpeg' : format;
    const originKey = `origin/${subpath}/${filename}`;

    console.log('Origin key:', originKey);

    try {
        // Fetch original image from S3
        const { Body } = await s3Client.send(
            new GetObjectCommand({
                Bucket: BUCKET,
                Key: originKey,
            })
        );

        // Convert stream to buffer and resize
        const imageBuffer = await Body.transformToByteArray();
        const resizedBuffer = await sharp(imageBuffer)
            .rotate()
            .resize(width, height, {
                fit: sharp.fit.inside,
                withoutEnlargement: true
            })
            .toFormat(sharpFormat)
            .toBuffer();

        const contentType = `image/${sharpFormat}`;

        // Upload resized image to S3 (fire and forget for faster response)
        s3Client.send(
            new PutObjectCommand({
                Bucket: BUCKET,
                Key: key,
                Body: resizedBuffer,
                ContentType: contentType,
                CacheControl: CACHE_CONTROL,
            })
        ).catch(err => {
            console.error('Failed to upload resized image:', err);
        });

        // Return resized image immediately
        return {
            status: 200,
            statusDescription: 'OK',
            body: resizedBuffer.toString('base64'),
            bodyEncoding: 'base64',
            headers: {
                ...response.headers,
                'content-type': [{
                    key: 'Content-Type',
                    value: contentType
                }]
            }
        };

    } catch (error) {
        console.error('Error processing image:', error);
        return response;
    }
};

