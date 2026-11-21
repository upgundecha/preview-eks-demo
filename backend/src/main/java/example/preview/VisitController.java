package example.preview;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping(path = "/api", produces = MediaType.APPLICATION_JSON_VALUE)
public class VisitController {
    private final JdbcTemplate db;
    private final String environment;
    private final String version;

    public VisitController(JdbcTemplate db,
                           @Value("${APP_ENVIRONMENT_ID:local}") String environment,
                           @Value("${APP_VERSION:local}") String version) {
        this.db = db;
        this.environment = environment;
        this.version = version;
    }

    @GetMapping("/visits")
    public VisitCount count() {
        Long visits = db.queryForObject("SELECT count(*) FROM visits", Long.class);
        return new VisitCount(visits == null ? 0 : visits, environment, version);
    }

    @PostMapping("/visits")
    public VisitCount add() {
        db.update("INSERT INTO visits DEFAULT VALUES");
        return count();
    }

    public record VisitCount(long visits, String environment, String version) {}
}
