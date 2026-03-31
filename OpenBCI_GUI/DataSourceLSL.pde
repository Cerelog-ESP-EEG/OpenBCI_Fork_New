///////////////////////////////////////////////////////////////////////////////
//
// This class configures and manages the connection to Lab Streaming Layer
// as a DataSource (Board subclass) for the OpenBCI GUI.
//
// LSL input enables the GUI to receive EEG data from a remote OpenBCI board
// or other EEG hardware via the Lab Streaming Layer protocol.
//
// The class extends Board so that it integrates with the existing DataWriterODF,
// DataLogger, and all widget infrastructure.
//
// Created: Adam Feuer, 2019 (original LslStream.pde)
// Refactored: Port to Board subclass architecture, 2024
//
///////////////////////////////////////////////////////////////////////////////

import org.apache.commons.lang3.tuple.Pair;
import org.apache.commons.lang3.tuple.ImmutablePair;

class DataSourceLSL extends Board {

    private LSL.StreamInlet lslInlet = null;
    private boolean lslStreaming = false;
    private int lslChannelCount = 8;   // default; updated from stream info in initializeInternal
    private int lslSampleRate = 250;   // default; updated from stream info in initializeInternal
    private boolean[] activeChannels;

    // Indices of the extra "virtual" channels appended to each sample row
    private int timestampChanIndex;
    private int sampleIndexChanIndex;

    // Populated in updateInternal(), returned by getNewDataInternal()
    private double[][] newFrameData;

    // Persistent sample counter that wraps 0-255 (matches PacketLossTracker's expected range)
    private int lslSampleCounter = 0;
    private static final int SAMPLE_INDEX_MAX = 255;

    DataSourceLSL(int numChannels) {
        this.lslChannelCount = numChannels;
        this.timestampChanIndex = numChannels;
        this.sampleIndexChanIndex = numChannels + 1;
    }

    // -----------------------------------------------------------------------
    // Board abstract method implementations
    // -----------------------------------------------------------------------

    @Override
    protected boolean initializeInternal() {
        println("LSL: Resolving EEG stream...");
        LSL.StreamInfo[] results;
        try {
            results = LSL.resolve_stream("type", "EEG");
        } catch (Exception e) {
            outputError("LSL: Exception while resolving EEG stream: " + e.getMessage());
            e.printStackTrace();
            return false;
        }

        if (results == null || results.length == 0) {
            outputError("LSL: No EEG streams found. Make sure your LSL source is running before starting a session.");
            return false;
        }

        println("LSL: Found " + results.length + " EEG stream(s). Connecting to the first one...");
        lslInlet = new LSL.StreamInlet(results[0]);

        try {
            LSL.StreamInfo info = lslInlet.info();
            lslChannelCount = info.channel_count();
            double nominalSRate = info.nominal_srate();
            if (nominalSRate > 0) {
                lslSampleRate = (int)nominalSRate;
            }
            println("LSL: Connected. Channels=" + lslChannelCount + ", SampleRate=" + lslSampleRate + " Hz");
        } catch (Exception e) {
            outputError("LSL: Error reading stream info: " + e.getMessage());
            e.printStackTrace();
            return false;
        }

        // Update virtual channel index positions now that we know the real channel count
        timestampChanIndex = lslChannelCount;
        sampleIndexChanIndex = lslChannelCount + 1;

        activeChannels = new boolean[lslChannelCount];
        Arrays.fill(activeChannels, true);

        return true;
    }

    @Override
    protected void uninitializeInternal() {
        lslStreaming = false;
        lslInlet = null;
        newFrameData = null;
        println("LSL: Disconnected from EEG stream.");
    }

    @Override
    protected void updateInternal() {
        if (!lslStreaming || lslInlet == null) {
            newFrameData = emptyData;
            return;
        }

        ArrayList<double[]> frameList = new ArrayList<double[]>();
        float[] sample = new float[lslChannelCount];

        try {
            // Non-blocking pull: timeout=0.0 returns immediately if no sample is available
            double timestamp = lslInlet.pull_sample(sample, 0.0);
            while (timestamp != 0.0) {
                double[] row = new double[getTotalChannelCount()];
                for (int i = 0; i < lslChannelCount; i++) {
                    row[i] = activeChannels[i] ? (double)sample[i] : 0.0;
                }
                row[timestampChanIndex] = timestamp;
                row[sampleIndexChanIndex] = lslSampleCounter;
                lslSampleCounter = (lslSampleCounter + 1) % (SAMPLE_INDEX_MAX + 1);
                frameList.add(row);
                timestamp = lslInlet.pull_sample(sample, 0.0);
            }
        } catch (Exception e) {
            println("LSL: Error reading sample from stream: " + e.getMessage());
        }

        // Convert ArrayList<double[]> (rows) to double[][] [channel][sample] format
        int frameSize = frameList.size();
        newFrameData = new double[getTotalChannelCount()][frameSize];
        for (int i = 0; i < frameSize; i++) {
            for (int j = 0; j < getTotalChannelCount(); j++) {
                newFrameData[j][i] = frameList.get(i)[j];
            }
        }
    }

    @Override
    protected double[][] getNewDataInternal() {
        if (newFrameData == null) return emptyData;
        return newFrameData;
    }

    // -----------------------------------------------------------------------
    // Streaming control – override Board defaults to avoid null packetLossTracker
    // -----------------------------------------------------------------------

    @Override
    public void startStreaming() {
        lslStreaming = true;
        packetLossTracker.onStreamStart();
        println("LSL: Started streaming.");
    }

    @Override
    public void stopStreaming() {
        lslStreaming = false;
        println("LSL: Stopped streaming.");
    }

    @Override
    public boolean isStreaming() {
        return lslStreaming;
    }

    @Override
    public boolean isConnected() {
        return lslInlet != null;
    }

    // -----------------------------------------------------------------------
    // DataSource interface implementations
    // -----------------------------------------------------------------------

    @Override
    public int getSampleRate() {
        return lslSampleRate;
    }

    @Override
    public int[] getEXGChannels() {
        int[] channels = new int[lslChannelCount];
        for (int i = 0; i < lslChannelCount; i++) {
            channels[i] = i;
        }
        return channels;
    }

    @Override
    public int getTimestampChannel() {
        return timestampChanIndex;
    }

    @Override
    public int getSampleIndexChannel() {
        return sampleIndexChanIndex;
    }

    @Override
    public int getMarkerChannel() {
        // No dedicated marker channel in LSL input; reuse sample index slot
        return sampleIndexChanIndex;
    }

    @Override
    public int getTotalChannelCount() {
        // EEG channels + one timestamp channel + one sample-index channel
        return lslChannelCount + 2;
    }

    @Override
    public void setEXGChannelActive(int channelIndex, boolean active) {
        if (activeChannels != null && channelIndex >= 0 && channelIndex < lslChannelCount) {
            activeChannels[channelIndex] = active;
        }
    }

    @Override
    public boolean isEXGChannelActive(int channelIndex) {
        if (activeChannels != null && channelIndex >= 0 && channelIndex < lslChannelCount) {
            return activeChannels[channelIndex];
        }
        return false;
    }

    @Override
    public Pair<Boolean, String> sendCommand(String command) {
        // LSL input streams do not accept commands
        return new ImmutablePair<Boolean, String>(Boolean.valueOf(false), "LSL: sendCommand not supported.");
    }

    @Override
    public void insertMarker(int value) {
        // Not supported for LSL input streams
    }

    @Override
    public void insertMarker(double value) {
        // Not supported for LSL input streams
    }

    @Override
    protected void addChannelNamesInternal(String[] channelNames) {
        // Board.getChannelNames() already assigns "EXG Channel N", "Timestamp",
        // and "Sample Index" based on getEXGChannels(), getTimestampChannel(),
        // and getSampleIndexChannel() – nothing extra needed here.
    }

    @Override
    protected PacketLossTracker setupPacketLossTracker() {
        // Sample index wraps 0-255, matching the range we write into sampleIndexChanIndex
        return new PacketLossTracker(getSampleIndexChannel(), getTimestampChannel(), 0, SAMPLE_INDEX_MAX);
    }
}
