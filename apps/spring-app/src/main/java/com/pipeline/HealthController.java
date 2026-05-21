package com.pipeline;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.sns.SnsClient;
import software.amazon.awssdk.services.sns.model.PublishRequest;
import software.amazon.awssdk.services.sns.model.PublishResponse;
import software.amazon.awssdk.services.sqs.SqsClient;
import software.amazon.awssdk.services.sqs.model.GetQueueAttributesRequest;
import software.amazon.awssdk.services.sqs.model.QueueAttributeName;

import java.util.Map;

@RestController
public class HealthController {

    @Value("${AWS_REGION:us-east-1}")
    private String awsRegion;

    @Value("${SNS_TOPIC_ARN:}")
    private String snsTopicArn;

    @Value("${SQS_QUEUE_URL:}")
    private String sqsQueueUrl;

    @GetMapping("/")
    public Map<String, Object> index() {
        return Map.of(
            "service", "spring-app",
            "version", "0.1.0",
            "status", "running",
            "environment", System.getenv().getOrDefault("ENVIRONMENT", "dev")
        );
    }

    @GetMapping("/health")
    public ResponseEntity<Map<String, String>> health() {
        var checks = new java.util.LinkedHashMap<String, String>();
        checks.put("service", "healthy");
        checks.put("sns", "unconfigured");
        checks.put("sqs", "unconfigured");

        if (!snsTopicArn.isEmpty()) {
            try (SnsClient sns = SnsClient.builder().region(Region.of(awsRegion)).build()) {
                sns.getTopicAttributes(b -> b.topicArn(snsTopicArn));
                checks.put("sns", "healthy");
            } catch (Exception e) {
                checks.put("sns", "unhealthy: " + e.getMessage());
            }
        }

        if (!sqsQueueUrl.isEmpty()) {
            try (SqsClient sqs = SqsClient.builder().region(Region.of(awsRegion)).build()) {
                sqs.getQueueAttributes(GetQueueAttributesRequest.builder()
                    .queueUrl(sqsQueueUrl)
                    .attributeNames(QueueAttributeName.APPROXIMATE_NUMBER_OF_MESSAGES)
                    .build());
                checks.put("sqs", "healthy");
            } catch (Exception e) {
                checks.put("sqs", "unhealthy: " + e.getMessage());
            }
        }

        boolean allHealthy = checks.values().stream()
            .allMatch(v -> v.equals("healthy") || v.equals("unconfigured"));
        return ResponseEntity.status(allHealthy ? 200 : 503).body(checks);
    }

    @PostMapping("/events")
    public ResponseEntity<Map<String, Object>> publishEvent(@RequestBody(required = false) Map<String, Object> body) {
        if (snsTopicArn.isEmpty()) {
            return ResponseEntity.status(503).body(Map.of("error", "SNS not configured"));
        }

        String message = body != null && body.containsKey("message")
            ? body.get("message").toString()
            : "hello from spring";

        try (SnsClient sns = SnsClient.builder().region(Region.of(awsRegion)).build()) {
            PublishResponse resp = sns.publish(PublishRequest.builder()
                .topicArn(snsTopicArn)
                .message(message)
                .messageAttributes(Map.of(
                    "source", software.amazon.awssdk.services.sns.model.MessageAttributeValue.builder()
                        .dataType("String")
                        .stringValue("spring-app")
                        .build()
                ))
                .build());

            return ResponseEntity.status(201).body(Map.of(
                "message_id", resp.messageId(),
                "message", message
            ));
        } catch (Exception e) {
            return ResponseEntity.status(500).body(Map.of("error", e.getMessage()));
        }
    }
}
