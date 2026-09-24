// A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
// Elten: Copyright (C) 2014-2026 Dawid Pieper
// Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
// This file was added for Klangten (GNU GPL v3, section 5a).
//
// YouTube for Android through NewPipeExtractor (GPLv3, TeamNewPipe): the same
// library NewPipe itself uses. The desktop client drives yt-dlp instead; the
// Ruby side (src/programs/youtube/__app.rb) keeps its own interface and only
// swaps the source of the data, so the screens are identical on both.
//
// Everything returns JSON, because that is what crosses the bridge to Ruby
// cheaply. Every call does network I/O and must not run on the main thread;
// Ruby calls them from its own thread.
package it.sixdots.klangten;

import android.util.Log;

import org.json.JSONArray;
import org.json.JSONObject;
import org.schabi.newpipe.extractor.InfoItem;
import org.schabi.newpipe.extractor.NewPipe;
import org.schabi.newpipe.extractor.ServiceList;
import org.schabi.newpipe.extractor.StreamingService;
import org.schabi.newpipe.extractor.channel.ChannelInfo;
import org.schabi.newpipe.extractor.channel.ChannelInfoItem;
import org.schabi.newpipe.extractor.channel.tabs.ChannelTabInfo;
import org.schabi.newpipe.extractor.downloader.Downloader;
import org.schabi.newpipe.extractor.downloader.Request;
import org.schabi.newpipe.extractor.downloader.Response;
import org.schabi.newpipe.extractor.linkhandler.ListLinkHandler;
import org.schabi.newpipe.extractor.localization.Localization;
import org.schabi.newpipe.extractor.playlist.PlaylistInfo;
import org.schabi.newpipe.extractor.playlist.PlaylistInfoItem;
import org.schabi.newpipe.extractor.search.SearchInfo;
import org.schabi.newpipe.extractor.services.youtube.YoutubeParsingHelper;
import org.schabi.newpipe.extractor.stream.AudioStream;
import org.schabi.newpipe.extractor.stream.StreamInfo;
import org.schabi.newpipe.extractor.stream.StreamInfoItem;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.zip.GZIPInputStream;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Locale;
import java.util.Map;

final class YouTube {
    private static final String TAG = "Klangten-youtube";
    private static final int TIMEOUT = 20000;
    private static final String USER_AGENT =
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:140.0) Gecko/20100101 Firefox/140.0";
    private static volatile boolean ready;

    private YouTube() {}

    private static synchronized void init() {
        if (ready) return;
        NewPipe.init(new UrlDownloader(), Localization.fromLocale(Locale.getDefault()));
        // Without this YouTube answers European requests with its consent page
        // and nothing can be parsed out of it.
        YoutubeParsingHelper.setConsentAccepted(true);
        ready = true;
    }

    private static StreamingService service() {
        return ServiceList.YouTube;
    }

    /** Whether YouTube works on this build at all (the library is linked in). */
    static int available() {
        try {
            init();
            return 1;
        } catch (Throwable e) {
            Log.w(TAG, "not available", e);
            return 0;
        }
    }

    /** type: "video", "channel" or "playlist". */
    static String search(String query, String type) {
        try {
            init();
            String filter = "channel".equals(type) ? "channels" : "playlist".equals(type) ? "playlists" : "videos";
            SearchInfo info = SearchInfo.getInfo(service(),
                    service().getSearchQHFactory().fromQuery(query, Collections.singletonList(filter), ""));
            return items(info.getRelatedItems());
        } catch (Throwable e) {
            return error(e);
        }
    }

    /** The videos of a channel; url may also be a channel id. */
    static String channelVideos(String url) {
        try {
            init();
            ChannelInfo channel = ChannelInfo.getInfo(service(), channelUrl(url));
            for (ListLinkHandler tab : channel.getTabs()) {
                if (!tab.getContentFilters().isEmpty() && "videos".equals(tab.getContentFilters().get(0))) {
                    return items(ChannelTabInfo.getInfo(service(), tab).getRelatedItems());
                }
            }
            return new JSONArray().toString();
        } catch (Throwable e) {
            return error(e);
        }
    }

    /** The videos of a playlist; url may also be a playlist id. */
    static String playlistVideos(String url) {
        try {
            init();
            return items(PlaylistInfo.getInfo(service(), playlistUrl(url)).getRelatedItems());
        } catch (Throwable e) {
            return error(e);
        }
    }

    /** One video with its audio streams, ready to play. */
    static String video(String idOrUrl) {
        try {
            init();
            StreamInfo info = StreamInfo.getInfo(service(), videoUrl(idOrUrl));
            JSONObject o = new JSONObject();
            o.put("id", info.getId());
            o.put("title", info.getName());
            o.put("author", info.getUploaderName());
            o.put("channel", info.getUploaderUrl());
            o.put("duration", info.getDuration());
            o.put("views", info.getViewCount());
            o.put("likes", info.getLikeCount());
            o.put("description", info.getDescription() == null ? "" : info.getDescription().getContent());
            o.put("date", info.getTextualUploadDate() == null ? "" : info.getTextualUploadDate());
            o.put("url", info.getUrl());
            JSONArray streams = new JSONArray();
            for (AudioStream stream : info.getAudioStreams()) {
                JSONObject s = new JSONObject();
                s.put("url", stream.getContent());
                s.put("bitrate", stream.getAverageBitrate() > 0 ? stream.getAverageBitrate() * 1000 : 0);
                s.put("codec", stream.getCodec() == null ? "" : stream.getCodec());
                s.put("container", stream.getFormat() == null ? "" : stream.getFormat().getSuffix());
                s.put("id", stream.getId());
                streams.put(s);
            }
            o.put("streams", streams);
            return o.toString();
        } catch (Throwable e) {
            return error(e);
        }
    }

    // --- helpers -------------------------------------------------------------------

    private static String items(List<? extends InfoItem> list) throws Exception {
        JSONArray out = new JSONArray();
        for (InfoItem item : list) {
            JSONObject o = new JSONObject();
            o.put("url", item.getUrl());
            o.put("title", item.getName());
            if (item instanceof StreamInfoItem) {
                StreamInfoItem stream = (StreamInfoItem) item;
                o.put("type", "video");
                o.put("author", stream.getUploaderName() == null ? "" : stream.getUploaderName());
                o.put("channel", stream.getUploaderUrl() == null ? "" : stream.getUploaderUrl());
                o.put("duration", stream.getDuration());
                o.put("views", stream.getViewCount());
                o.put("date", stream.getTextualUploadDate() == null ? "" : stream.getTextualUploadDate());
                o.put("id", videoId(stream.getUrl()));
            } else if (item instanceof ChannelInfoItem) {
                o.put("type", "channel");
                o.put("id", item.getUrl());
            } else if (item instanceof PlaylistInfoItem) {
                PlaylistInfoItem playlist = (PlaylistInfoItem) item;
                o.put("type", "playlist");
                o.put("author", playlist.getUploaderName() == null ? "" : playlist.getUploaderName());
                o.put("id", item.getUrl());
            } else {
                continue;
            }
            out.put(o);
        }
        return out.toString();
    }

    // Ruby tells errors apart by this shape; anything else is a result.
    private static String error(Throwable e) {
        Log.w(TAG, "request failed", e);
        try {
            JSONObject o = new JSONObject();
            o.put("error", e.getClass().getSimpleName() + ": " + String.valueOf(e.getMessage()));
            return o.toString();
        } catch (Exception ignored) {
            return "{\"error\":\"unknown\"}";
        }
    }

    private static String videoId(String url) {
        if (url == null) return "";
        int index = url.indexOf("v=");
        if (index >= 0) {
            String rest = url.substring(index + 2);
            int end = rest.indexOf('&');
            return end >= 0 ? rest.substring(0, end) : rest;
        }
        int slash = url.lastIndexOf('/');
        return slash >= 0 ? url.substring(slash + 1) : url;
    }

    private static String videoUrl(String value) {
        if (value == null || value.isEmpty()) return "";
        if (value.startsWith("http://") || value.startsWith("https://")) return value;
        return "https://www.youtube.com/watch?v=" + value;
    }

    private static String channelUrl(String value) {
        if (value.startsWith("http://") || value.startsWith("https://")) return value;
        return "https://www.youtube.com/channel/" + value;
    }

    private static String playlistUrl(String value) {
        if (value.startsWith("http://") || value.startsWith("https://")) return value;
        return "https://www.youtube.com/playlist?list=" + value;
    }

    /** The extractor asks the host to perform its HTTP requests; plain URLConnection does. */
    private static final class UrlDownloader extends Downloader {
        @Override
        public Response execute(Request request) throws IOException {
            HttpURLConnection connection = (HttpURLConnection) new URL(request.url()).openConnection();
            connection.setConnectTimeout(TIMEOUT);
            connection.setReadTimeout(TIMEOUT);
            connection.setRequestMethod(request.httpMethod());
            connection.setInstanceFollowRedirects(true);
            boolean hasAgent = false;
            for (Map.Entry<String, List<String>> header : request.headers().entrySet()) {
                if ("user-agent".equalsIgnoreCase(header.getKey())) hasAgent = true;
                for (String value : header.getValue()) {
                    connection.addRequestProperty(header.getKey(), value);
                }
            }
            // Without a desktop agent YouTube redirects to m.youtube.com, whose
            // pages the extractor cannot read (same agent NewPipe itself sends).
            if (!hasAgent) connection.setRequestProperty("User-Agent", USER_AGENT);
            byte[] body = request.dataToSend();
            if (body != null) {
                connection.setDoOutput(true);
                try (OutputStream out = connection.getOutputStream()) {
                    out.write(body);
                }
            }
            int code = connection.getResponseCode();
            InputStream stream = code >= 400 ? connection.getErrorStream() : connection.getInputStream();
            // The extractor asks for gzip itself, and then URLConnection hands
            // the compressed bytes through unchanged.
            String encoding = connection.getContentEncoding();
            if (stream != null && encoding != null && encoding.toLowerCase(Locale.ROOT).contains("gzip")) {
                stream = new GZIPInputStream(stream);
            }
            String content = stream == null ? "" : read(stream);
            Log.d(TAG, "HTTP " + code + " " + request.url() + " -> " + connection.getURL()
                    + " " + content.length() + " bytes, ytInitialData=" + content.contains("ytInitialData")
                    + ", consent=" + content.contains("consent.youtube.com")
                    + ", cookies=" + request.headers().get("Cookie"));
            return new Response(code, connection.getResponseMessage(), connection.getHeaderFields(),
                    content, connection.getURL().toString());
        }

        private String read(InputStream stream) throws IOException {
            ByteArrayOutputStream buffer = new ByteArrayOutputStream();
            byte[] chunk = new byte[16384];
            int n;
            while ((n = stream.read(chunk)) > 0) buffer.write(chunk, 0, n);
            stream.close();
            return new String(buffer.toByteArray(), StandardCharsets.UTF_8);
        }
    }

    /** Keeps ProGuard from stripping what the extractor reaches by reflection. */
    static List<String> keep() {
        return new ArrayList<>();
    }
}
