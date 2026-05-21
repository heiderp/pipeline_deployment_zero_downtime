package com.pipeline;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.web.servlet.MockMvc;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

@SpringBootTest
@AutoConfigureMockMvc
class ApplicationTests {

    @Autowired
    private MockMvc mockMvc;

    @Test
    void indexReturnsServiceInfo() throws Exception {
        mockMvc.perform(get("/"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.service").value("spring-app"))
            .andExpect(jsonPath("$.status").value("running"));
    }

    @Test
    void healthReturns200WhenDependenciesUnconfigured() throws Exception {
        mockMvc.perform(get("/health"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.service").value("healthy"))
            .andExpect(jsonPath("$.sns").value("unconfigured"))
            .andExpect(jsonPath("$.sqs").value("unconfigured"));
    }

    @Test
    void publishEventWithoutSnsReturns503() throws Exception {
        mockMvc.perform(post("/events").contentType("application/json").content("{\"message\":\"test\"}"))
            .andExpect(status().isServiceUnavailable())
            .andExpect(jsonPath("$.error").value("SNS not configured"));
    }
}
